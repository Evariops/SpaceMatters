# SPEC-05 — Raffinement fichier au zoom (vue globale par dossier)

> **Findings** : S5 (README l'évoque), complète A8 (couleur de tuile). Optionnel.
> **Contrainte produit (imposée)** : la **vue globale reste strictement par dossier** — lisibilité prioritaire. Le détail fichier est une propriété du **niveau de zoom courant**, jamais de la carte entière.
> **Statut** : ✅ **IMPLÉMENTÉ & LIVE-VÉRIFIÉ** (Axe B2 — tuiles-fichiers au zoomRoot, sous-dossiers agrégés).

## 0. Résultat d'implémentation

- **Axe B2** : `TreemapLayout.compute(..., rootFiles:)` — seuls les fichiers directs du **zoomRoot** (depth 0) sont matérialisés en tuiles individuelles ; les sous-dossiers restent agrégés (récursion avec `files: nil`). L'overview reste strictement par dossier.
- **`TreemapTile.file: FileTileInfo?`** (nom, taille au métrique courant, extension) porte la tuile-fichier ; couleur par **extension du fichier** (`treemapTypeColor`, cohérent avec la légende), label = nom du fichier, hover/menu/double-clic (Open/Reveal/Copy) dédiés. **Live-vérifié** : `demo05` montre video.mp4/archive.zip/photo.png/document.pdf/notes.txt en tuiles colorées distinctes, `subfolder` agrégé.
- **Résidu** : si la liste de fichiers est plafonnée (`maxFilesPerFolder`), le reliquat reste un bloc agrégé « other files » (proportions exactes).
- **Mémoire** : les fichiers viennent du `fileCache` **borné** existant (≤ 2000/dossier, par répertoire visité), rempli au zoom-in via `filesIn(zoomRoot)`. Non matérialisé **pendant** le scan (évite la ré-énumération à 10 Hz) — raffinement une fois le scan stabilisé.
- **Test** : `zoomRootRefinesIntoFileTiles` (zoomRoot → N tuiles-fichiers + sous-dossier agrégé ; overview → 1 bloc agrégé, 0 tuile-fichier).

## 1. Objectif

Quand on **entre dans un dossier** (clic/double-clic/zoom), la région de ce dossier se **raffine jusqu'aux fichiers** ; à l'inverse, la vue d'ensemble n'affiche **que des dossiers**. On ne disperse jamais de tuiles-fichiers sur toute la carte : la lisibilité globale prime.

## 2. État actuel (vérifié)

- Modèle « 1 nœud/répertoire » ([FSNode.swift](../Sources/MacDirStats/Model/FSNode.swift)) : les fichiers ne sont pas des objets ; agrégés dans `directFiles*`.
- Le treemap rend le sous-arbre de `zoomRoot` ([TreemapView.swift](../Sources/MacDirStats/Views/TreemapView.swift)) ; le zoom (double-clic tuile, breadcrumb, ⌘↑) existe et fonctionne.
- Aujourd'hui, dans un dossier zoomé, les sous-dossiers sont des tuiles mais les **fichiers directs sont agrégés** en une tuile-feuille (couleur = dominant direct, cf. A8). Énumération on-demand : `filesIn` ([ScanController.swift:344](../Sources/MacDirStats/ViewModel/ScanController.swift#L344)), non persistée.

## 3. Principe de conception

- **Niveau overview** (`zoomRoot` = racine du scan, ou tout niveau « de loin ») : tuiles **par dossier** uniquement — comportement actuel **préservé**.
- **Entrée dans un dossier** (`zoomRoot` = ce dossier) : la carte affiche les **fichiers directs** de ce dossier comme tuiles individuelles, entremêlés avec ses sous-dossiers (toujours agrégés).
- **Sortie de zoom** : retour à l'agrégat par dossier ; la mémoire fichier du dossier quitté est **libérée**.

→ Le raffinement suit le **zoom**, pas un seuil global. C'est ce qui garantit une overview lisible.

## 4. Axes & tradeoffs

- **Axe A — Seuil de taille global** (afficher les fichiers partout où ils dépassent le seuil de tuile) : **rejeté** — disperserait des fichiers dans la vue globale, contraire à la contrainte produit. ❌
- **Axe B — Raffinement piloté par le zoom (recommandé)** : matérialiser les tuiles-fichiers **seulement pour le `zoomRoot` courant**. Overview intacte, mémoire bornée au dossier ouvert.
  - **B1** : fichiers du `zoomRoot` **et** de ses sous-dossiers de 1ᵉʳ niveau (raffinement d'un cran — plus riche, un peu plus dense).
  - **B2** : fichiers directs du `zoomRoot` uniquement ; les sous-dossiers restent des tuiles agrégées jusqu'à ce qu'on y entre (plus conservateur, le plus lisible). **Défaut recommandé.**
- **Stockage** : blob colonnaire compact par répertoire raffiné `[(nameOffset: UInt32, logical: Int64, physical: Int64, extIndex)]` + arène de noms (~24 o/fichier), **rempli au zoom-in, vidé au zoom-out**.

**Recommandé : Axe B / B2**, activable par un toggle « détail fichiers » (défaut on), avec possibilité de passer à B1.

## 5. Plan d'implémentation

1. `FileBlock` compact (colonnaire) construit à la volée pour le `zoomRoot` quand on y entre (réutilise l'énumération de `filesIn`, mais persistée compactement).
2. `TreemapLayout.compute` : si le nœud rendu **est le `zoomRoot`** (B2) et possède un `FileBlock`, subdiviser sa région en tuiles-fichiers (squarify des tailles fichiers) au lieu d'une tuile-feuille unique. Au-delà de ce niveau → agrégat par dossier inchangé.
3. Cycle de vie mémoire : remplir dans `zoom(into:)`, libérer dans `zoomOut`/`resetZoom`/`navigate` quand on quitte le dossier (borne stricte : au plus le contenu fichier d'un dossier à la fois, +1 niveau si B1).
4. Hit-test / hover / sélection au niveau fichier **uniquement dans la zone raffinée** ; ailleurs, comportement nœud actuel.
5. Couleur par fichier via `ExtKey`/palette (déjà cohérent avec la légende). Profiter du passage pour A8 (dominant pondéré du sous-arbre sur les tuiles-dossier agrégées).

## 6. Vérification

- **Live (méthode établie)** : overview → tuiles **dossier** (capture, lisible) ; zoomer dans `sub1` → fichiers de `sub1` en tuiles individuelles (capture) ; ⌘↑ → retour à l'agrégat dossier. Vérifier qu'à l'overview **aucune** tuile-fichier n'apparaît.
- **Test** : `FileBlock` round-trip (noms/tailles/ext) ; budget ≤ 24 o/fichier ; libération à la sortie de zoom.

## 7. Risques & hypothèses

- 🔬 Transition visuelle zoom-in/out (apparition/disparition des tuiles-fichier) : animer ou basculer proprement au relayout (`recompute`).
- Choix B1 vs B2 à calibrer sur des dossiers réels (densité vs richesse).
- Interaction avec le hit-test qui raisonne aujourd'hui en nœuds : introduire un type de tuile « fichier » distinct.

## 8. Effort & dépendances

**2–3 jours.** Indépendant (synergie A8). Le pilotage par zoom réutilise l'infrastructure `zoomRoot` existante.
