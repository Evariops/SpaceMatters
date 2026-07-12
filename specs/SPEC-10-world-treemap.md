# SPEC-10 — Treemap-monde persistant : caméra continue, LOD hiérarchique, navigation « carte »

> **Findings** : profilage resize du 2026-07-12 (Instruments, Game Performance, build release, M4 Pro) — pendant un live-drag : **main thread saturé à ~80 %**, **~16 ms CPU par frame présentée** (budget 120 Hz : 8,3 ms) → ~50 fps effectifs avec hitches à 25-46 ms. Répartition : **~22 % code app** (layout continu ~10 %, reconstruction `tiles`/repack ~6 %, présent ~4 % — dont création d'**IOSurface à chaque frame**, le `drawableSize` changeant invalide le pool de drawables), **~78 % machinerie AppKit/SwiftUI** (layout du chrome, contraintes, AttributeGraph — deux passes par frame). GPU : **0,3 %** d'utilisation, p50 0,13 ms — totalement désœuvré.
> **Défaut de paradigme constaté** (captures à deux tailles de fenêtre) : le layout est une **fonction du viewport**. Le gel des décisions discrètes ([TreemapLayout.Cache](../Sources/SpaceMatters/Views/TreemapLayout.swift#L57)) rend le resize *monotone*, mais le cache est invalidé à chaque bump de `version` (tick de scan à 10 Hz, refresh FSEvents) et les décisions sont re-décidées **au rect courant de la fenêtre** — deux invalidations à deux tailles → deux mondes sans rapport, les gros blocs changent de place. Le « monde » est re-roulé en permanence.
> **Décision d'architecture (proposée)** : inverser le paradigme, à la manière d'un moteur de jeu open-world — **le layout est une fonction pure des données, calculée en coordonnées monde ; le viewport n'est qu'une caméra ; le niveau de détail est une décision de rendu ; les changements de données sont des retouches locales animées, jamais un re-roll global.** En prime produit : le treemap devient **navigable façon Google Maps** (pan au trackpad, zoom continu vers le curseur, le détail qui se révèle en zoomant).
> **Prérequis** : PR #24 (renderer Metal seul chemin de rendu, [Camera.ortho](../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift#L39) découplant déjà viewport et instances).
> **Statut** : 📋 **PROPOSÉ** — à planifier. Remplace la mécanique de « référence gelée » de SPEC-09/PR #17 par un modèle monde ; généralise SPEC-05 ; prépare l'activation 3D de SPEC-09 §9.

## 1. Objectif

Que plus **aucune** interaction caméra (resize de fenêtre, pan, zoom) ne recalcule ni ne re-packe quoi que ce soit : une frame caméra = une matrice, budget **< 1 ms** CPU main thread. Que la **position d'un dossier dans le monde soit stable** — entre deux resizes, entre deux ticks de scan, entre deux refreshes — et que tout changement structurel légitime (données qui bougent, aspect qui dérive trop) soit une **transition animée locale**, pas une téléportation globale. Et ouvrir la feature produit : **naviguer le disque comme une carte** — deux doigts pour se déplacer, pincer pour plonger, le niveau de détail qui suit.

## 2. État actuel du code (vérifié)

Ce qui existe et sur quoi on s'appuie :

- **La caméra existe déjà** : [Camera.ortho(viewport:)](../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift#L39) projette un rect-monde arbitraire sur le drawable ; l'animation de zoom ([startZoomAnimation](../Sources/SpaceMatters/Views/TreemapView.swift#L679)) anime déjà une caméra **sur des instances figées** — la preuve de concept du modèle est dans le code.
- **Le gel partiel existe** : [TreemapLayout.Cache](../Sources/SpaceMatters/Views/TreemapLayout.swift#L57) mémoïse par nœud les décisions discrètes (breaks de rangées, orientations) et ne rejoue que la géométrie continue. Défauts : invalidation globale par `(metric, version, root)` ([ScanController.treemapLayout](../Sources/SpaceMatters/ViewModel/ScanController.swift#L540)), référence = rect fenêtre du moment, et la géométrie continue + [relayout()](../Sources/SpaceMatters/Views/TreemapView.swift#L399) + [packInstances](../Sources/SpaceMatters/Views/TreemapView.swift#L442) retournent **à chaque frame** de resize.
- **Le renderer copie les instances à chaque render()** (triple buffer) — pas de chemin « caméra seule, buffer inchangé ».
- **L'overlay CG ne sait pas suivre la caméra** (masqué pendant le zoom animé, hover désactivé pendant l'animation) ; le hit-test ([tileAt](../Sources/SpaceMatters/Views/TreemapView.swift#L599)) est en coordonnées vue, valide seulement caméra à l'identité.
- **SPEC-05** : les fichiers du seul zoom root sont des tuiles ([filesIn](../Sources/SpaceMatters/ViewModel/ScanController.swift#L562), `rootFileTiles` mémoïsé) ; la navigation est un **état structurel** `zoomRoot` ([zoom(into:)](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1150)) qui re-layoute.
- Échelle : scan hôte type = **713 695 dossiers / 3,9 M fichiers** (capture du jour) ; profondeur possible > 20 niveaux.

## 3. Conception retenue

### 3.1 Le monde : coordonnées hiérarchiques parent-relatives
Chaque nœud stocke son rect **relatif au parent, dans [0,1]²** (Float32, 16 o), décidé par le squarify sur les poids des enfants — **jamais en pixels, jamais fonction de la fenêtre**. Le rect-monde absolu d'un nœud est la **composition** des rects relatifs de sa lignée, calculée en `Double` au moment du rendu pour les seuls sous-arbres visibles. Propriétés :

- **Stabilité par construction** : le rect relatif d'un nœud ne change que si les poids de sa fratrie changent — pas au resize, pas au zoom, pas quand un cousin lointain bouge.
- **Précision** : à 4 M de fichiers, une tuile profonde peut mesurer 10⁻⁶ du monde ; composer en Double puis **re-baser caméra** (coordonnées caméra-relatives avant conversion Float pour le GPU — le *floating origin* des moteurs de jeu) élimine la casse de précision Float32 en zoom profond.
- **Rangement** : extension de `Cache.Entry` (les entrées par nœud existent déjà) — pas de champ ajouté à `FSNode`, le modèle reste pur. Entrées construites **paresseusement** (seulement pour les nœuds LOD-développés) et évincées LRU hors viewport, comme des tuiles de carte.

L'**aspect du monde** suit paresseusement l'aspect de la fenêtre : pendant un drag la caméra étire (déformation tolérée, bornée par hystérésis ~±20 %) ; au `viewDidEndLiveResize` ou au franchissement du seuil, **re-bake global animé** (morph, §3.4). Décision ⚖️ : c'est le seul événement autorisé à re-décider globalement — et il est **rare et animé**.

### 3.2 La caméra : navigation carte continue
`Camera` s'enrichit d'un état `(centre monde, échelle)` avec conversions vue↔monde exactes (inverse pour le hit-test). Gestes :

- **Pan** : scroll deux doigts / drag (mode main). **Zoom** : pincement et molette, **vers le curseur** (le point sous la souris reste sous la souris — l'invariant Google Maps). **Double-clic** : zoom-to-fit animé du dossier (remplace le re-layout de `zoom(into:)` par un mouvement de caméra — l'animation actuelle devient *la* navigation). **⌘0 / breadcrumb / Home** : fit d'un ancêtre.
- **Bornes** : zoom-min = monde entier (léger rubber-band), zoom-max = quand le plus petit fichier visible atteint ~40 px de côté.
- **`zoomRoot` devient un dérivé de la caméra** : le dossier le plus profond dont le rect-monde contient ~le viewport. Breadcrumb, liste, résumé a11y s'y accrochent comme aujourd'hui — la sélection liste→carte fait un fit caméra, la navigation carte→liste suit le dérivé. L'état structurel disparaît ; l'URL mentale devient « où est la caméra ».

### 3.3 LOD hiérarchique par taille projetée
Le `maxDepth`/`minSide` statiques disparaissent au profit d'une règle par nœud, évaluée sur la **taille projetée à l'écran** (px = taille monde × échelle caméra) :

- côté projeté < **T_collapse** (~8 px) → le dossier est rendu **agrégé** : une tuile de sa couleur `dominantExt` (le champ existe, [FSNode](../Sources/SpaceMatters/Model/FSNode.swift#L46)) ;
- côté projeté > **T_expand** (~14 px) → ses enfants sont développés (hystérésis T_expand > T_collapse contre le *popping* au bord du seuil) ;
- côté projeté > **T_files** (~400 px de côté) → ses **fichiers propres** apparaissent en tuiles individuelles — **généralisation de SPEC-05** : plus seulement le zoom root, tout dossier assez gros à l'écran. Layouts de fichiers calculés à la demande, cache LRU.

La **subdivision est animée** : quand un dossier se développe, ses enfants naissent du rect parent et interpolent vers leurs rects (morph §3.4) — le « tile split » de Google Maps ; l'inverse au repli. Le set d'instances GPU est géré en **ranges contigus par sous-arbre développé**, reconstruits seulement quand le set LOD change ; une frame caméra-seule **ne réécrit aucun buffer** (nouveau chemin `render(cameraOnly:)` qui réutilise le dernier buffer — la copie actuelle par frame disparaît).

### 3.4 Morph : tout re-bake est une transition
Le vertex shader reçoit **deux buffers d'instances** (avant/après, appariés par nœud) + un uniforme `t` ; il interpole origine/taille (~200 ms, easing actuel). S'applique à : re-bake d'aspect (fin de drag), **ticks de scan et refreshes FSEvents** (coalescés à 10 Hz max — le monde « respire » au lieu de téléporter, le défaut des captures disparaît par construction), développement/repli LOD, futur passage 2D↔3D. Instances orphelines (nœud supprimé) fondent vers taille 0 ; nouvelles instances naissent du rect parent.

### 3.5 Stabilité sous scan : invalidation locale (« local moves »)
L'invalidation `version` cesse d'être globale : le scanner/FSEvents connaissent les **sous-arbres sales** — seules leurs entrées (rects relatifs, décisions) sont re-décidées ; les fratries dont les poids n'ont dérivé que sous un **ε** (~2 %) gardent leurs décisions (re-géométrie continue seule). C'est l'esprit « stable treemaps via local moves » (Sondag et al., TVCG 2018) appliqué à notre cache existant. Pendant le scan initial, le monde **se construit progressivement** : les entrées apparaissent au fil des données (streaming), le LOD borne ce qui est calculé — on ne layoute jamais 713 k dossiers d'un coup, seulement le visible + une marge.

### 3.6 Présentation : pooling du drawable, overlay caméra-aware
- **Drawable** : `drawableSize` arrondi au **palier de 256 px** supérieur, cadré via `contentsRect` → le pool d'IOSurfaces survit au drag (les allocations par frame mesurées au profil disparaissent). 🔬 à valider avec `presentsWithTransaction` ; repli = réallocation au seul `viewDidEndLiveResize`.
- **Overlay** (spotlight sélection + hover) : ses 2-3 rects passent en **coordonnées monde**, transformés par la caméra à chaque present (coût trivial) → l'overlay **suit** pan/zoom/morph, le hover reste actif pendant les mouvements (l'inhibition actuelle saute). Le hit-test passe par l'inverse caméra (vue → monde → descente par containment dans les rects relatifs).

## 4. Plan d'implémentation — jalons

**M1 — Monde figé + caméra passive (~2-3 j)** : rects parent-relatifs dans `Cache.Entry` ; composition monde→instances ; resize = caméra seule + re-bake animé en fin de drag ; `render(cameraOnly:)` ; pooling drawable ; overlay/hit-test via inverse caméra ; hover actif pendant les mouvements. *Sortie : resize 120 Hz, part app ~0 dans le profil, plus aucun saut de blocs au resize.*

**M2 — Navigation carte (~2-3 j)** : pan/zoom-au-curseur (scroll, pincement, molette), double-clic = fit animé, bornes + rubber-band, `zoomRoot` dérivé (breadcrumb/liste/a11y suivent), ⌘0/Home = fit racine. *Sortie : la feature « Google Maps ».*

**M3 — LOD hiérarchique + fichiers (~4-5 j)** : seuils projetés + hystérésis, entrées lazy/LRU, ranges d'instances par sous-arbre, subdivision-morph, fichiers par dossier au-delà de T_files (généralise SPEC-05). *Sortie : zoomer révèle le détail, dézoomer agrège — à profondeur illimitée.*

**M4 — Streaming & scan vivant (~3-4 j)** : invalidation par sous-arbre sale, ε-stabilité des décisions, morphs coalescés sur ticks/FSEvents, construction progressive pendant le scan. *Sortie : un scan en cours est un monde qui se remplit en douceur.*

*(M5 = 3D : hors périmètre — voir §8.)*

## 5. Vérification

- **Stabilité (le bug des captures)** : script de référence — même scan, séquence resize → tick de version → resize ; les centroïdes des 20 plus gros blocs ne doivent pas bouger de > quelques % du monde (hors morphs explicites). Test unitaire pur sur les rects relatifs : re-layout à aspects différents ⇒ rects relatifs identiques.
- **Perf** : re-profil Instruments du même scénario (protocole du 2026-07-12 : attach + warm-up ~10 s à absorber) — frame caméra < 1 ms CPU app ; zéro `CAIOSurfaceCreate` pendant un drag ; presents à la cadence vsync pendant pan/zoom.
- **Précision** : zoom au max sur le plus petit fichier d'un scan 4 M — pas de jitter de géométrie (valide le re-basage caméra).
- **LOD** : franchissements de seuils répétés (zoom oscillant) sans popping ni churn d'instances (hystérésis) ; budget mémoire entrées LRU borné et mesuré.
- **Interaction** : hover/clic/menu/sélection pendant pan, zoom **et** morph ; breadcrumb cohérent avec le dérivé caméra ; a11y (résumé du dossier dominant) ; tests `TreemapLayout` existants verts (le squarify lui-même ne change pas).

## 6. Risques & hypothèses (🔬)

- 🔬 **Précision Float en zoom profond** — mitigée par parent-relatif + composition Double + re-basage caméra ; à prouver au jalon M1 (test du §5).
- 🔬 **`contentsRect` × `presentsWithTransaction`** sur CAMetalLayer — à valider tôt ; repli documenté (§3.6).
- 🔬 **Appariement avant/après du morph** sous scan agressif (nœuds qui naissent/meurent en rafale) — coalescence 10 Hz + naissance-du-parent doivent suffire ; sinon dégrader en cross-fade.
- 🔬 **Modèle mental `zoomRoot` dérivé** : la liste et la carte peuvent diverger transitoirement pendant un pan — l'UX du breadcrumb « suit la caméra » est à éprouver (prototype M2 avant de figer).
- ⚖️ **Molette = zoom** (convention carte) vs scroll = pan (convention document) : trancher au M2 (proposition : trackpad pan + pincement zoom, molette souris = zoom).
- **Mémoire** : entrées complètes sur un arbre pathologique — bornée par LOD-lazy + LRU, à mesurer M3.
- **Déformation pendant le drag** (aspect monde ≠ fenêtre dans la bande d'hystérésis) : assumée, bornée, corrigée par le re-bake animé de fin de drag.

## 7. Effort & dépendances

**~11-15 j** en 4 jalons livrables indépendamment (chacun laisse l'app meilleure qu'avant). Dépend de : PR #24 mergée (Metal-only). Aucune dépendance externe. Les 78 % de taxe AppKit/SwiftUI au resize de *fenêtre* ne sont **pas** dans ce périmètre (chantier chrome séparé) — mais pan/zoom, eux, ne touchent pas la fenêtre : la navigation carte tourne intégralement dans le budget GPU/caméra.

## 8. Périmètre — ce que cette SPEC fait / ne fait PAS

**Fait** : le paradigme monde (layout = données), caméra continue pan/zoom, LOD hiérarchique projeté (dossiers **et** fichiers), morphs sur tout changement, streaming sous scan, stabilité spatiale garantie et testée.
**Ne fait PAS** : la 3D (hauteurs, perspective, orbite) — mais ce modèle en est le **prérequis propre** : SPEC-09 §9 s'active ensuite par caméra + hauteur sur un monde inchangé, le LOD et le morph s'appliquant tels quels aux boîtes. Pas de minimap (nice-to-have, à cadrer après M2). Pas de refonte du chrome SwiftUI (les 78 % du profil resize-fenêtre — chantier séparé). Le look des tuiles (palette, cushion, gouttières) ne change pas.

## 9. Addendum post-implémentation (PR #25 — QA visuelle du 2026-07-12)

Amendements actés pendant l'implémentation, après quatre passes de QA visuelle sur un scan réel (4 M fichiers) :

- **§3.6 pooling du drawable : abandonné.** Le 🔬 s'est confirmé — le crop `contentsRect` produit des bandes noires pendant le drag. Le repli documenté s'applique : `drawableSize` exact par frame ; le resize étant devenu caméra-only, la réallocation d'IOSurface est le seul coût résiduel, assumé.
- **§3.4 morph de subdivision : « appear-in-place », pas grow-from-parent.** La croissance géométrique depuis le rect parent superpose les enfants entre eux et sur leurs voisins pendant la transition (gros carrés fantômes au zoom). Les tuiles nouvelles apparaissent à leur place finale ; seules les tuiles présentes dans les deux builds glissent, et leurs **couleurs cross-fadent** (la renormalisation de luminosité fond au lieu de sauter). Un rebuild en plein morph repart de l'état affiché (lerp à t), pas de la cible précédente.
- **§3.4 scan vivant : téléportation, pas morph.** À 10 Hz de restructurations violentes, des glissades de 220 ms n'atterrissent jamais — la carte se délite en carrés épars sur la sous-couche. Un scan actif rebuild instantanément (chaque frame est un pavage cohérent) ; les morphs s'appliquent à la vie calme post-scan (FSEvents, suppressions, métrique, re-bake d'aspect, LOD).
- **§3.5 ε ancré aux parts de décision + garde de qualité.** La dérive mesurée contre la dernière revalidation (baseline glissante) laissait les décisions dériver sans borne par petits pas (lamelles 10:1). L'ε se mesure contre les parts **au moment de la décision**, la dérive d'aspect du rect du nœud (±25 %) re-décide aussi, et une garde auto-réparante re-décide localement au-delà d'un pire ratio de 5:1.
- **Sous-couche parent** : chaque dossier développé (et bloc fichiers subdivisé) est peint sous ses enfants — les enfants cullés (< 0,5 px) montrent la couleur du dossier au lieu de percer un trou vers le fond ; hover/clic y tombent sur le dossier.
- **Molette normalisée** : deltas précis ÷12, facteur borné à [0.5, 2] par événement (×1.15/cran, aligné sur le pincement).
- Les tuiles disparues sont retirées sans fondu (le fondu à zéro impliquerait du blending — pipeline opaque conservé).
