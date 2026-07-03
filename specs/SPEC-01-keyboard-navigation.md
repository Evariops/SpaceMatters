# SPEC-01 — Navigation clavier & liste native

> **Findings** : J3.1 (app 100 % souris), J4.2 (pas de ⌘⌫ ni multi-sélection), partiellement J3.7 (tri/colonnes). Renvoie à D-E du plan.
> **Statut** : ✅ **IMPLÉMENTÉ** (Axe B — `NSTableView` en `NSViewRepresentable`). Voir [DirectoryTable.swift](../Sources/MacDirStats/Views/DirectoryTable.swift).

## 0. Résultat d'implémentation

- `DirectoryTable: NSViewRepresentable` (NSScrollView + `MacDirTableView`), lignes = `NSHostingView(OutlineRowView)` → **zéro régression visuelle** (rendu SwiftUI réutilisé tel quel).
- Souris **déterministe** : `MacDirTableView.hitTest` renvoie la table pour tout point in-bounds (cellules purement visuelles) ; la sélection passe par `NSTableView.mouseDown`/`row(at:)`, pas par le forwarding de la chaîne de responders. Chevron plier/déplier par géométrie dans `mouseDown`.
- Clavier : ↑/↓ natifs, ←/→ plier/parent & déplier/enfant, ⏎ zoom/ouvrir, **⌘⌫ corbeille de la sélection (gaté `!isScanning`)**, espace Quick Look, type-select natif.
- **Multi-sélection** (`allowsMultipleSelection`) : `ScanController.selectedRowIDs` (set) + `setListSelection(_:primary:)` — le *primary* pilote le treemap, le set pilote ⌘⌫. Menu contextuel par ligne (Quick Look/Open/Reveal/Copy/Trash/Delete) via `menu(for:)`.
- Synchro treemap↔liste : `selectedRowID` reste la source unique ; `updateNSView` idempotent, `scrollRowToVisible` sur `revealTarget`.
- **Vérifié** : build vert ; 12 tests (dont `listSelectionTracksPrimaryAndSet`, `deletingAncestorClearsStaleMultiSelection`) ; **live** — table native rend l'outline avec fidélité totale (chevrons/icônes/barres/tailles/tri), sélection dessinée, **chaque ligne exposée à l'AX** avec label (« Folder alpha, 1000 KB »), aucun crash. Le pilotage par événements synthétisés (clic/flèches) était bloqué par un panneau *Secure Event Input* d'une autre app ; logique couverte par les tests ViewModel.
- **Reste optionnel (hors scope 100 %)** : J3.7 en-têtes de colonnes triables — explicitement « facultatif » au §5.7. Menu contextuel multi-cible (aujourd'hui ⌘⌫ couvre la corbeille de masse).

## 1. Objectif

Rendre la liste de répertoires pilotable au clavier pour l'utilisateur cible (dev senior) : flèches ↑/↓ pour parcourir, ←/→ pour plier/déplier, ⏎ pour zoomer/ouvrir, ⌘⌫ pour envoyer à la corbeille, barre espace pour QuickLook, multi-sélection (⇧/⌘-clic) pour le nettoyage de masse, et type-select (frappe d'un préfixe).

## 2. État actuel du code (vérifié)

- [DirectoryListView.swift](../Sources/MacDirStats/Views/DirectoryListView.swift) : `List { ForEach(rows) { OutlineRowView… } }`, `listStyle(.plain)`, lignes custom. Sélection via `.onTapGesture { select() }`, zoom via `.simultaneousGesture(TapGesture(count: 2))`, chevron via un `.onTapGesture` dédié, `.contextMenu`. La sélection est `controller.selectedRowID` (dérive `selection`).
- `visibleRows()` ([ScanController.swift:398](../Sources/MacDirStats/ViewModel/ScanController.swift#L398)) produit un **tableau plat** (dirs + fichiers mélangés, biggest-first) — déjà le bon modèle pour une table.
- Le zoom/sélection/expansion sont centralisés dans `ScanController` (bien).

## 3. Leçon acquise (vérifiée en live)

`List(selection:)` + `.tag(row.id)` a été essayé et **piloté à l'écran** :
- la `List` ne prend **pas** le focus clavier (flèches inertes) ;
- la sélection native ne s'engage **pas** au simple clic tant que les lignes portent leurs propres `onTapGesture`/`contentShape`/double-clic ;
- retirer le `onTapGesture` **casse** le clic simple sans débloquer les flèches.

→ La navigation clavier **n'est pas un bolt-on** sur la `List` SwiftUI actuelle.

## 4. Axes de conception & tradeoffs

- **Axe A — Tout-SwiftUI `List(selection:)`** : dépouiller les lignes de tous leurs gestes, laisser la `List` posséder la sélection, ré-ajouter chevron/double-clic/hover autrement. *Tradeoff* : combat les quirks de focus SwiftUI (observés), rendu de la sélection native à re-styliser, comportement flèches non garanti sur `List` à contenu custom. **Risque élevé, résultat incertain.**
- **Axe B — `NSViewRepresentable` autour d'un `NSTableView` (recommandé)** : contrôle **déterministe** du clavier (arrows, ⌘⌫, type-select, multi-select), du focus (first responder), de la sélection et du défilement. C'est ainsi que les apps Mac denses (Finder-like) procèdent. *Tradeoff* : plus de code (≈250–350 lignes), un pont SwiftUI↔AppKit à maintenir. *Bénéfice* : robuste, testable, extensible (colonnes triables J3.7, multi-sélection J4.2 gratuites).
- **Axe C — `NSOutlineView`** : gère l'arborescence nativement (disclosure), mais on a déjà un modèle *plat* (`visibleRows()`) et l'expansion vit dans le contrôleur → `NSTableView` colle mieux, moins de friction.

**Recommandation : Axe B.** Un `NSTableView` en `NSViewRepresentable`, alimenté par `visibleRows()`, cellules rendues via `NSHostingView(OutlineRowView)` pour **réutiliser le design SwiftUI existant** (zéro régression visuelle). Le clavier/focus/multi-sélection deviennent natifs et fiables.

## 5. Plan d'implémentation

1. **`DirectoryTable: NSViewRepresentable`** produisant `NSScrollView` + `NSTableView` (une colonne, `rowHeight` fixe, `usesAlternatingRowBackgroundColors = false`, style plain).
2. **Data source / delegate** (`Coordinator`) : lignes = `controller.visibleRows()` ; `numberOfRows`, `viewFor:` → `NSHostingView(rootView: OutlineRowView(row:…))` réutilisé (pool via `makeView(withIdentifier:)`).
3. **Sélection** : `allowsMultipleSelection = true`. `tableViewSelectionDidChange` → pousser vers `controller.selectedRowID`/`selection` ; réciproquement, `updateNSView` re-sélectionne quand `controller.selectedRowID` change (breadcrumb/treemap → liste).
4. **Clavier** (sous-classe `NSTableView.keyDown` ou `NSResponder`) :
   - ↑/↓ : natif.
   - ←/→ : plier/déplier la ligne dossier sélectionnée (`controller.toggleExpanded`).
   - ⏎ : `controller.zoom(into:)` (dossier) / `openItem` (fichier).
   - ⌘⌫ : corbeille de la (ou des) ligne(s) sélectionnée(s), **gaté par `!isScanning`** (J4.4), via le flux async `remove(...)` existant.
   - espace : QuickLook des URLs sélectionnées.
   - type-select : natif via `tableView(_:typeSelectStringFor:)`.
5. **Multi-sélection → actions de masse** : `controller.remove(rows:)` itérant le flux async ; menu contextuel `contextMenu(forSelectionType:)` équivalent.
6. Remplacer `List{…}` par `DirectoryTable(controller:)` dans `DirectoryListView`. Conserver `revealTarget`/scroll-to (via `scrollRowToVisible`).
7. Facultatif (J3.7) : en-têtes de colonnes triables (nom / taille / nb fichiers / date) → `sortDescriptors` → nouveau tri dans le contrôleur.

## 6. Vérification

- **Live (méthode établie)** : `--open <fixture>`, capture d'écran, `key code 125/126` (↓/↑) → la sélection se déplace (vérifiable au surlignage) ; ⌘⌫ sur une ligne → corbeille + total décrémenté ; ⇧-clic → multi-sélection ; espace → panneau QuickLook.
- **Tests ViewModel** : `controller.selectRow`, multi-remove, gating pendant scan (étendre `NavigationTests`).

## 7. Risques & hypothèses

- 🔬 **Perf `NSHostingView`-par-ligne** sur très grande liste : mitiger par réutilisation de vues + `OutlineRowView` léger ; à mesurer sur un dossier de 100 k lignes visibles (rare, la liste est virtualisée à O(visible)).
- 🔬 Synchronisation bidirectionnelle sélection liste ↔ treemap sans boucle d'événements : garder `selectedRowID` comme source unique, `updateNSView` idempotent.
- Anneau de focus / apparence de sélection à accorder au thème (dessiner la sélection dans `OutlineRowView` via `isSelected`, désactiver la sélection dessinée par AppKit).

## 8. Effort & dépendances

**1–2 jours.** Aucune dépendance. Débloque J3.1, J4.2, et prépare J3.7 (colonnes) et une partie de SPEC-08 (focus/rotor accessibles nativement).
