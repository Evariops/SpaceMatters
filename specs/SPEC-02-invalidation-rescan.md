# SPEC-02 — Invalidation & re-scan de sous-arbre

> **Findings** : B1 (cure de fond — le garde-fou est déjà en place), **A6** (table des types périmée après suppression, non résolu), A7 (compteur dossiers — déjà patché ponctuellement), J4.4 (delete pendant scan — gaté), D1 (TOCTOU). Renvoie à D-B/S2 du plan.

## 1. Objectif

Remplacer la **chirurgie manuelle** des agrégats dans `remove()` par une **invalidation + re-scan ciblé** du répertoire parent. Bénéfices : supprime la classe entière de comptabilité fragile (A6 impossible à corriger autrement — voir §3), élimine tout risque résiduel d'incohérence, et fournit la **brique commune** réutilisée par FSEvents (SPEC-04).

## 2. État actuel du code (vérifié)

- `remove(directory:)`/`applyDirectoryRemoval` ([ScanController.swift:507+](../Sources/MacDirStats/ViewModel/ScanController.swift#L507)) : soustrait les agrégats de chaque ancêtre (atomics), remonte `zoomRoot`/`selection`/`expanded` hors du sous-arbre (garde-fou B1), décrémente `dirCount` (A7), détache le nœud.
- **Ce qui n'est PAS ajusté** : `extStats` du scanner (A6). La ventilation par extension du sous-arbre supprimé n'est **pas stockée** dans l'arbre (les nœuds ne gardent que `dominantExt` + agrégats). Donc soustraire les contributions par extension du sous-arbre supprimé est **infaisable** sans re-énumérer.
- Le scanner sait déjà scanner un sous-arbre : `DirectoryScanner(root:, seeds:[Seed(path:node:)])` — une suppression = une nouvelle seed sur `node.parent`.

## 3. Le nœud du problème (A6)

`extStats: [ExtKey: ExtStat]` est **global au scan**, construit par accumulation pendant le scan. Après suppression d'un sous-arbre, il contient encore les octets/■comptes des fichiers supprimés. Trois façons d'en sortir :

- **Stocker par nœud la table d'extensions** : coût mémoire non borné (à l'opposé du parti « 1 nœud/répertoire, low-RAM »). ❌
- **Re-scanner le sous-arbre supprimé *avant* suppression pour connaître ses contributions et les soustraire** : possible mais fragile (double travail, race avec le scan). ⚠️
- **Invalidation + re-scan du parent (recommandé)** : après une suppression réussie, re-scanner le répertoire parent reconstruit ses enfants **et** ré-accumule `extStats` pour ce sous-arbre. Reste à réconcilier avec la table globale.

## 4. Axes de conception & tradeoffs

- **Axe A — Consolider la mutation en place** : ajouter la soustraction `extStats`. *Infaisable proprement* (§3). ❌
- **Axe B — Re-scan du parent, table d'extensions recalculée globalement** : sur suppression, (1) détacher le nœud (comme aujourd'hui, garde-fous B1 conservés), (2) relancer un `DirectoryScanner` seedé sur `parent.path` dans un **sous-arbre neuf**, (3) swap atomique de `parent._children`, (4) **reconstruire `extStats` en re-walkant tout l'arbre restant** (les fichiers ne sont pas en mémoire → re-énumération disque des dossiers, coûteux) *ou* maintenir `extStats` comme somme de tables par-seed recalculées.
- **Axe C — Re-scan du parent + `extStats` maintenu par sous-arbre** : le scanner tient `extStats` **par répertoire de premier niveau** (ou par seed), de sorte qu'invalider un sous-arbre = soustraire sa sous-table + ré-accumuler. Plus d'état, mais soustraction O(1) exacte.

**Recommandation : Axe B, variante pragmatique.** Le re-scan du parent est la vraie cure de B1/A6/A7. Pour `extStats`, **marquer le panneau "File types" comme approximatif** juste après la suppression *et* le recalculer par re-énumération **paresseuse** du parent re-scanné (le re-scan du parent réaccumule déjà les extensions du sous-arbre ; il suffit de soustraire l'ancienne contribution du parent connue avant le re-scan). Décision-clé documentée ci-dessous.

**Décision `extStats`** : avant le re-scan, **snapshotter la table d'extensions restreinte au sous-arbre du parent** (obtenable par une passe de re-scan « à blanc » du parent, ou en soustrayant post-re-scan). *La plus simple et exacte* : le re-scan du parent produit sa **nouvelle** sous-table d'extensions ; on tient une `extStats` **par nœud-parent-direct-de-seed** afin de faire `global = Σ sous-tables`. 🔬 à valider : le surcoût mémoire d'une sous-table par enfant-de-seed (borné au nb d'extensions distinctes, petit).

## 5. Plan d'implémentation

1. `DirectoryScanner` : exposer un mode **re-scan de sous-arbre** — `rescan(node:path:)` qui repart d'une seed unique, construit un `FSNode` racine temporaire, et retourne `(children, directFiles, extSubtable, dirCount)`.
2. `ScanController.remove(...)` : sur succès disque → au lieu de la chirurgie d'agrégats, appeler `invalidate(subtree: node.parent)`.
3. `invalidate(subtree:)` : lance le re-scan (détaché, non bloquant), applique sur MainActor : swap `_children`, recalcul des agrégats des ancêtres (delta = nouveau − ancien sous-total), mise à jour `extStats` (Σ sous-tables), `dirCount`, ré-résolution de `selection`/`zoomRoot` **par chemin** (pas par identité de nœud, car les nœuds sont neufs — réutiliser `path(for:)` + une résolution inverse).
4. Conserver les garde-fous B1 (ils deviennent redondants mais inoffensifs) le temps de la migration, puis les retirer.
5. Gating pendant scan (J4.4) : déjà en place ; l'invalidation ne s'exécute que `phase != .scanning`.

## 6. Vérification

- **Tests** (étendre `NavigationTests`) : après suppression d'un sous-arbre contenant des `.mp4`, **`extStats` ne contient plus les `.mp4` supprimés** (verrouille A6) ; `dirCount`, agrégats et absence de nœud pendant restent corrects ; `selection`/`zoomRoot` ré-résolus par chemin.
- **Live** : supprimer `sub2` de la fixture → le panneau « File types » perd les `.bin` de `sub2/deep`, total/dossiers cohérents (capture avant/après).

## 7. Risques & hypothèses

- 🔬 Ré-résolution `selection`/`zoomRoot` par chemin après swap de nœuds : nécessite un index chemin→nœud transitoire.
- 🔬 Coût du re-scan d'un très gros parent (ex. supprimer un dossier dans `/` re-scanne toute la racine) : borner en re-scannant **le nœud supprimé lui-même n'existe plus**, donc on re-scanne son parent — potentiellement énorme. Mitigation : ne re-scanner que si le parent a peu d'enfants restants, sinon garder la soustraction d'agrégats (exacte) et n'invalider QUE `extStats` du sous-arbre (hybride).
- Le choix hybride (agrégats par soustraction + extStats par sous-table) est peut-être le meilleur compromis simplicité/coût — à trancher au moment de l'implémentation.

## 8. Effort & dépendances

**1–2 jours.** Aucune dépendance amont. **Débloque SPEC-04 (FSEvents)** qui réutilise `invalidate(subtree:)`.
