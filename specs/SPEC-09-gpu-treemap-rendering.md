# SPEC-09 — Rendu GPU **3D-natif** du treemap (Metal, projection 2D orthographique)

> **Findings** : chantier **perf-resize** (continuation de la PR #17 « solution C »). Profilage : après avoir supprimé la taxe SwiftUI (`NSHostingView.layout` 5373→101, `dispatchActions` 3395→1), le coût a basculé sur la **rastérisation CPU** des tuiles — `CGContextFillRect` ≈ 7482 échantillons pendant un drag, sur le `NSEventThread`. Sur un arbre pathologique (`.build/ModuleCache`, des milliers de tuiles minuscules) le remplissage par tuile reste le plancher.
> **Décision d'architecture (actée)** : le moteur de rendu est **3D-natif dès le départ** — vraie géométrie 3D, caméra, matrices MVP, depth buffer. L'affichage courant est sa **projection orthographique top-down** : tuiles plates (hauteur = 0) vues d'aplomb → **iso-visuel strict** avec la visu 2D actuelle. Une projection ortho de tuiles plates **préserve exactement les proportions** (pas de fuyantes), donc le 2D d'aujourd'hui est mathématiquement identique. **Passer en 3D** (plus tard, §9) = changer la **caméra** (perspective + orbite) et donner une **hauteur** aux tuiles — **aucune réécriture**, le pipeline est déjà 3D.
> **Contrainte produit** : **on garde les tuiles 2D actuelles.** Le 3D reste **différé (+3–6 mois)** côté produit.
> **Statut** : 📋 **PROPOSÉ** — à planifier. La couture (NSView séparant layout/interaction de `draw()`) est déjà en place (PR #17), ce qui rend le renderer Metal un **remplacement local** du seul dessin des tuiles.

## 1. Objectif

Rendre le treemap sur le **GPU** au lieu du CPU, via un **pipeline 3D natif** dont le rendu courant est une **projection orthographique 2D**, pour que le resize (et à terme le zoom, puis la 3D) soit fluide même sur des dizaines de milliers de tuiles — **sans toucher au visuel ni à l'interaction aujourd'hui**. Le raisonnement, prouvé sur ce projet :

- L'ancien `Canvas` + `.drawingGroup()` était fluide **parce qu'il passait par le GPU** (Metal offscreen) ; son coût réel était la **taxe de reconcile SwiftUI** autour, pas le dessin.
- La solution C (PR #17) a supprimé cette taxe (AppKit pilote le resize) mais a **rapatrié le dessin sur le CPU** (`CALayer.draw` → Core Graphics).
- **Metal = les deux gains à la fois** : dessin GPU **et** pas de taxe SwiftUI.

Un treemap est un ensemble de quads colorés axis-aligned : le cas d'école du **GPU instancing** (un seul draw call pour N tuiles). Le remplissage séquentiel de milliers de rects sur un thread devient un upload de N instances + **un** appel de dessin, rastérisé en parallèle.

## 2. État actuel du code (vérifié)

Couture (posée par la PR #17) — le dessin est **déjà isolé** du reste :

- [TreemapView.swift:13](../Sources/SpaceMatters/Views/TreemapView.swift#L13) `struct TreemapView` (wrapper SwiftUI : observation + overlay hover + a11y) → [:70](../Sources/SpaceMatters/Views/TreemapView.swift#L70) `TreemapRepresentable: NSViewRepresentable` → [:110](../Sources/SpaceMatters/Views/TreemapView.swift#L110) `final class TreemapNSView: NSView, CALayerDelegate`.
- Deux `CALayer` : [:133](../Sources/SpaceMatters/Views/TreemapView.swift#L133) `tileLayer` (tuiles, redessiné au relayout) + [:134](../Sources/SpaceMatters/Views/TreemapView.swift#L134) `overlayLayer` (hover + sélection, redessiné seul).
- **Le goulot** : [`drawTiles`](../Sources/SpaceMatters/Views/TreemapView.swift#L387) — boucle par tuile avec [`ctx.setFillColor` + `ctx.fill(r)`](../Sources/SpaceMatters/Views/TreemapView.swift#L398-L399), [`drawLinearGradient` par tuile](../Sources/SpaceMatters/Views/TreemapView.swift#L405) (cushion), remplissage de dim, `stroke` de bordure. **Tout sur CPU.**
- Contournement actuel du coût pixel : [`viewWillStartLiveResize` passe `contentsScale` à 1](../Sources/SpaceMatters/Views/TreemapView.swift#L208) (¼ des pixels pendant le drag, re-net à la fin). Pansement — Metal le rend inutile (§4.7).
- Orientation : rects top-left, contexte CG bottom-left → [`flip(_:_:)` par tuile](../Sources/SpaceMatters/Views/TreemapView.swift#L383). Bug historique (survol inversé verticalement) corrigé côté hit-test [:490](../Sources/SpaceMatters/Views/TreemapView.swift#L490).

Ce qui **ne bouge pas** (et donc n'est pas réécrit) :

- **Layout** : [`TreemapLayout.compute`](../Sources/SpaceMatters/Views/TreemapLayout.swift#L77) + [`Cache`](../Sources/SpaceMatters/Views/TreemapLayout.swift#L49) size-independent + [`squarifySorted`](../Sources/SpaceMatters/Views/TreemapLayout.swift#L192) ; seule la **placement** re-tourne par frame, la structure triée est mémoïsée. Reste CPU (bon marché après cache). Piloté par [`ScanController.treemapLayout`](../Sources/SpaceMatters/ViewModel/ScanController.swift#L453), invalidé par [`version`](../Sources/SpaceMatters/ViewModel/ScanController.swift#L30).
- **Couleurs** : [`computeColors`](../Sources/SpaceMatters/Views/TreemapView.swift#L302) + LUT `(hueIndex, bucket luminance)` → aujourd'hui `CGColor` ([`cgColor(for:weight:)`](../Sources/SpaceMatters/Views/TreemapView.swift#L326)), via [`Theme.treemapTypeColor(hueIndex:weight:)`](../Sources/SpaceMatters/App/Theme.swift#L61). **Seul changement** : sortir des **RGBA packés** (`SIMD4<Float>`) au lieu de `CGColor`.
- **Interaction** : [`tileAt`](../Sources/SpaceMatters/Views/TreemapView.swift#L490), hover ([:507](../Sources/SpaceMatters/Views/TreemapView.swift#L507)), `mouseUp` ([:524](../Sources/SpaceMatters/Views/TreemapView.swift#L524)), `menu(for:)` ([:568](../Sources/SpaceMatters/Views/TreemapView.swift#L568)) — **inchangés** (hit-test CPU sur `tiles`).
- **Overlay** actuel : [`drawOverlay`](../Sources/SpaceMatters/Views/TreemapView.swift#L432) (1 spotlight + 1 liseré + 1 outline) en CoreGraphics — **migre en 2ᵉ passe Metal** (§4.5) ; le code CG reste comme fallback.

Aucun usage Metal aujourd'hui (grep : seul un `.drawingGroup()` résiduel dans `KubernetesResultView`, hors sujet).

## 3. Conception retenue

Le renderer est un **pipeline Metal à quads instancés, 3D-natif, projeté en ortho 2D**. Les décisions, chacune actée :

1. **GPU instancing** — un quad unité (généré depuis `[[vertex_id]]`, sans VBO) dessiné **N fois** via `drawPrimitives(instanceCount: N)` ; chaque instance lit son `{origin, size, color}` dans un **buffer d'instances** indexé par `[[instance_id]]`. Un seul draw call pour toutes les tuiles. *(Modèle OpenGL équivalent : `glDrawArraysInstanced` + attribut par-instance ; MSL au lieu de GLSL, pipeline state pré-compilé au lieu de l'état global mutable.)*

2. **3D-natif, projection ortho** — vertices 3D, **matrice MVP** pilotée par une caméra, depth buffer actif. Aujourd'hui : `height = 0`, caméra orthographique top-down → sortie pixel-identique au 2D. Ce choix a **le même coût par frame** qu'un pipeline 2D figé, mais rend la 3D (§9) gratuite (caméra + hauteur) au lieu d'une réécriture. La matrice MVP remplace le `flip(_:_:)` par-tuile (flip encodé une fois dans la caméra).

3. **Rendu à la demande** — `CAMetalLayer` piloté manuellement (draw appelé depuis `setFrameSize`/`apply`), GPU au repos quand rien ne change. Pas de `MTKView` (évite un sous-view + delegate ; on garde notre `NSView` unique et son interaction).

4. **Buffer shared + anneau** — `MTLStorageModeShared` (mémoire unifiée Apple Silicon : CPU écrit, GPU lit, **zéro copie/blit**). Anneau de 2–3 buffers + `DispatchSemaphore` pour que le CPU n'écrase pas un buffer encore lu par le GPU (utile pendant la rafale de frames d'un live-resize).

5. **Bordures par gouttière inset** — effacer la couche en `treemapBorder`, puis dessiner chaque fill **inséré de 0,6 px** → la couleur de bord transparaît comme des gouttières. Zéro géométrie de bordure, look « grille » net (le trick classique des treemaps).

6. **Overlay = 2ᵉ passe Metal** — sélection + hover rendus par une poignée d'instances, bordure/dim en **fragment shader** (SDF). C'est *le* lieu des futurs effets de highlight (§4.8) ; le mettre en Metal dès maintenant évite d'écrire un overlay CPU qu'on arracherait ensuite. **Phase 1 : reproduit le look actuel à l'identique.**

## 4. Plan d'implémentation

Principe : **remplacer uniquement les tripes du dessin**. Layout, couleurs (source), hit-test et interaction restent tels quels.

### 4.1 Nouveau fichier `Views/TreemapMetalRenderer.swift`
Encapsule tout le Metal, testable/remplaçable, sans polluer `TreemapNSView` :
- `device: MTLDevice`, `commandQueue`, `pipelineState: MTLRenderPipelineState`, `depthState: MTLDepthStencilState`, anneau de `instanceBuffers: [MTLBuffer]`, `inflightSemaphore`, une `Camera` (§4.2).
- Struct d'instance **3D-native** (compacte, alignée) :
  ```
  struct TileInstance {          // 48 o : 3× SIMD4<Float>
      var origin: SIMD4<Float>   // x, y, z(=0) en espace monde ; w = padding
      var size:   SIMD4<Float>   // largeur, profondeur, hauteur(=0 aujourd'hui), w = padding
      var color:  SIMD4<Float>   // RGBA linéaire ; le dim est déjà folded dedans
  }
  ```
  Aujourd'hui `origin.z = 0` et `size.height = 0` → chaque instance est un **quad plat** posé sur le plan sol ; demain `size.height = f(size|count|depth)` → une **boîte** extrudée, **même struct**.
- `func render(instances:, drawable:, camera: Camera, borderColor:)`.

### 4.2 Caméra & convention monde (le cœur du 3D-natif)
- **Monde** : plan **sol XZ** (comme une carte / une ville), axe **Y = hauteur** (« code city » : les tuiles gisent au sol, les boîtes montent en Y). Le layout squarify (rects top-left en pixels) est mappé sur le plan sol par une transformation fixe (échelle + flip top-left → monde).
- **Caméra** = `view` (position/orientation) × `projection`, encapsulée dans `Camera { viewProjection() -> float4x4 }`. **Aujourd'hui** : caméra **orthographique**, au-dessus, regardant droit vers le bas (−Y), *up* aligné pour reproduire la disposition des rects → ortho top-down = les rects 2D au pixel près (garantie iso-visuel).
- **Depth buffer** activé dès maintenant (`MTLDepthStencilState`, `.depth32Float`) : inerte tant que les tuiles sont plates, **prêt** pour le recouvrement des boîtes en 3D. Coût négligeable.

### 4.3 Shaders `Views/Treemap.metal`
- **Vertex** : sommet de quad (`vertex_id` → 2 triangles ; demain 12 triangles de boîte) placé par `instance.origin/size`, transformé en clip space par la **MVP caméra** (uniforme). Passe `uv∈[0,1]` et la taille pixel au fragment.
- **Fragment** : `fill = instance.color` ; **cushion** = reproduction des 3 stops actuels ([TreemapView.swift:160-165](../Sources/SpaceMatters/Views/TreemapView.swift#L160-L165)) — blanc α .16 en haut → 0 à 0.45 → noir α .20 en bas, composité sur le fill, **skippé** si tuile < 6 px (comme aujourd'hui) ; **bordure** par gouttière inset (fond pré-effacé en `treemapBorder`, fill inséré de 0,6 px). Sortie sRGB (§6).

### 4.4 Buffer d'instances — discipline d'alloc
- Réutiliser un `MTLBuffer` par slot d'anneau, **agrandi seulement** quand `tiles.count` dépasse la capacité (comme `sizeScratch`). Jamais d'alloc par frame.
- Remplissage : boucle unique sur `tiles`, culling sub-pixel **côté CPU avant écriture** (on n'envoie pas une tuile ≤ 0,5 px — déjà filtré [:395](../Sources/SpaceMatters/Views/TreemapView.swift#L395)). Écriture directe dans le buffer shared.
- Couleurs : `computeColors` produit des `SIMD4<Float>` (mêmes valeurs que `treemapTypeColor`, converties une fois) au lieu de `CGColor`. Le **dim** (highlight/search) est **folded** dans la couleur au remplissage → un simple recalcul du buffer sur changement de highlight (peu fréquent), pas de seconde passe.

### 4.5 Intégration dans `TreemapNSView`
- Remplacer `tileLayer` (CALayer CPU) par une `CAMetalLayer` (`tileMetalLayer`), `device` assigné, `pixelFormat` calibré (§6), `framebufferOnly = true`, `presentsWithTransaction = true` (§6 gotcha resize).
- `relayout()`/`apply()` inchangés dans leur logique ; à la fin, au lieu de `tileLayer.setNeedsDisplay()` → `renderer.render(...)` synchrone.
- `setFrameSize` : mettre à jour `tileMetalLayer.drawableSize = bounds.size * scale`, puis render. **Supprimer** le hack `contentsScale = 1` du live-resize (§4.7).
- **Overlay** (sélection + hover) : 2ᵉ passe Metal dans le même drawable (spotlight `evenOdd` → test dedans/dehors + liseré SDF ; outline hover → SDF). **Phase 1 : look actuel à l'identique.** Le `drawOverlay` CG reste comme fallback (§4.6).

### 4.6 Repli (défensif)
Si `MTLCreateSystemDefaultDevice()` renvoie `nil` (jamais sur macOS 15, mais by-the-book) → conserver le chemin CoreGraphics actuel (`drawTiles`/`drawOverlay`) en fallback. Le code de dessin CG **n'est pas supprimé**, il devient le plan B → **pas de régression possible**.

### 4.7 Bonus attendu : retrait du pansement live-resize
Metal rastérise le plein retina quasi gratuitement → plus besoin du `contentsScale = 1` pendant le drag ([:208-217](../Sources/SpaceMatters/Views/TreemapView.swift#L208-L217)). Le treemap reste **net pendant** le resize, pas seulement à la fin.

### 4.8 Headroom effets — débloqué par §4.5, **hors périmètre** (Phase 2)
Une fois bordures/sélection/hover en fragment shader, ces effets deviennent des changements d'un uniforme, impayables sur CPU par frame — **à ne PAS allumer en Phase 1** (romprait l'iso-visuel). Consignés comme cap produit, à cadrer dans un chantier dédié : glow de sélection animé (falloff de distance + `time`), bordures SDF anti-aliasées, dim animé (fondu 150 ms), matches de recherche qui « respirent ». *(Les effets animés impliquent un rendu 60 fps borné par `CADisplayLink` le temps de la transition — pas une boucle continue.)*

## 5. Vérification

- **Iso-visuel (méthode captures établie)** : capture côté-à-côté **avant (CG) / après (Metal)** sur le même scan — couleurs, sheen cushion, gouttières, dim (highlight extension + search), spotlight de sélection, outline de hover. Doivent être indiscernables (tolérance sRGB, §6).
- **Orientation** : re-vérifier le bug historique — survoler les tuiles **du haut** highlight bien celles du haut (le flip est maintenant dans la projection).
- **Perf (objectif du chantier)** : `sample`/Instruments (Metal System Trace) sur `.build/ModuleCache` pendant un drag continu → la rastérisation CPU (`CGContextFillRect`) **disparaît** du profil ; temps de frame GPU < 1 ms ; `NSEventThread` déchargé.
- **Interaction** : clic (reveal), double-clic (zoom/open/zoomOut), menu contextuel, sélection depuis la liste → **inchangés** (hit-test CPU non touché).
- **Tests** : la logique testée (`TreemapLayout`, `squarify*`) est inchangée → tests existants verts. Ajouter un test unitaire sur le **packing d'instances** (N tuiles → N `TileInstance` attendus, culling sub-pixel appliqué) — pur, sans GPU.

## 6. Risques & hypothèses (🔬)

- 🔬 **Espace colorimétrique** : CG dessine en sRGB device RGB ; le drawable Metal doit matcher (`.bgra8Unorm_srgb` vs conversion gamma dans le shader). Mal calibré → tuiles plus claires/sombres. À figer en capture avant de généraliser.
- 🔬 **`CAMetalLayer` + live-resize** : sans `presentsWithTransaction = true` + présentation **synchrone** (`commit` → `waitUntilScheduled` → `drawable.present()` dans la même transaction que le changement de bounds), la couche Metal **retarde/tearing** derrière la fenêtre pendant le drag. C'est LE gotcha ; à traiter dès le départ.
- 🔬 **Bordure inset** : gouttière opaque `treemapBorder` vs stroke semi-transparent 0,6 px de l'actuel. Valider en capture ; repli possible sur une bordure SDF (fragment shader) si l'écart déplaît.
- **Placement CPU comme nouveau plancher** : une fois la raster GPU gratuite, le coût résiduel par frame devient `squarifySorted` (O(n) arith + alloc des rects). Si mesuré gênant : réutiliser les buffers de rects, voire paralléliser — **hors périmètre**, à mesurer après coup.
- **Intel Macs** (macOS 15, minoritaires) : `storageModeShared` OK mais moins optimal ; pas bloquant.

## 7. Effort & dépendances

**2–3 jours.** Indépendant. La couture NSView de la PR #17 est le prérequis — **déjà en place**. Aucune dépendance externe (Metal est système). Le code CG actuel reste comme fallback, donc pas de régression possible en cas de souci device.

## 8. Périmètre — ce que cette SPEC fait / ne fait PAS

**Fait** : un renderer **3D-natif** (géométrie 3D, caméra, MVP, depth) rendu en **projection orthographique 2D**, iso-visuel avec les tuiles actuelles, sur GPU. Tuiles **et** overlay (sélection/hover) en Metal.
**Ne fait PAS** (aujourd'hui) :
- Aucun changement visible : visu, palette, layout, interaction **inchangés**. **Iso-visuel strict.**
- Pas de texte dans les tuiles (resté retiré).
- **Pas d'effets animés** : l'overlay Metal reproduit le look actuel à l'identique ; le headroom shader (§4.8) est débloqué mais **éteint** — c'est Phase 2.
- Pas de hauteur ≠ 0, pas de caméra perspective, pas d'orbite : la **3D reste débranchée** (caméra ortho top-down, `size.height = 0`). Voir §9.

## 9. Activation 3D — différée côté **produit** (+3–6 mois), déjà **architecturée**

Le 3D n'est **pas** un futur chantier de refonte, c'est un **basculement de configuration** d'un moteur déjà 3D. Rien à réécrire — on « rebranche » ce que §4.2 a posé :

- **Caméra** : `projection` ortho → **perspective** ; `view` top-down → **inclinée + orbitable**. Pipeline, shaders, buffer d'instances : identiques.
- **Hauteur** : `size.height` passe de 0 à `f(donnée)` → les quads plats deviennent des **boîtes** (le vertex shader passe de 2 à 12 triangles ; même struct d'instance).
- **Depth buffer** : déjà actif (§4.2) → recouvrement des boîtes correct sans rien changer.
- **Cushion → shading** : le sheen top→bottom devient un vrai éclairage par normale de face — même emplacement dans le fragment shader.

Dimensions candidates pour la hauteur : `size(metric)`, `fileCount` ([FSNode.swift:28](../Sources/SpaceMatters/Model/FSNode.swift#L28)), profondeur d'arbre. ⚠️ **`FSNode` n'a aucun champ temporel** (vérifié : identique à `main`) — une hauteur « âge/fraîcheur » impliquerait d'ajouter `mtime` au scan (dépendance à cadrer séparément, hors de cette SPEC).

→ Décision produit : **tuiles 2D maintenant**, activation 3D dans 3–6 mois. Cette SPEC garantit que cette activation sera un **réglage de caméra + un attribut de hauteur**, pas une réécriture.
