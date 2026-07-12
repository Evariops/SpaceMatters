# SPEC-11 — Refresh incrémental par répertoire : la carte vivante

> **Findings** (session 2026-07-12, QA live sur volume 315 GiB / 3,9 M fichiers) : un fichier de 4 GiB créé **à la racine du home** déclenche, au Refresh, un re-scan parallèle **du home entier** — ~25 s (après PR #26, qui a borné un walk d'extensions mono-thread qui portait ce même refresh à plusieurs **minutes**). Cause structurelle : FSEvents n'est exploité que comme *marqueur de sous-arbre sale* ([handleDiskChanges](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1109) → `nearestNode`), et [refreshDirty](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1139) → [invalidate(subtree:)](../Sources/SpaceMatters/ViewModel/ScanController.swift#L970) reconstruit tout le sous-arbre. Le chiffre du bandeau, lui, est un **delta statfs global** ([volumeFreeBytes](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1100)) — il capte aussi le bruit des autres process.
> **Ce qu'on n'exploite pas** : la sémantique précise de FSEvents en granularité répertoire — un événement sans `MustScanSubDirs` signifie « **le contenu direct de CE répertoire** a changé ». Une passe `getattrlistbulk` non récursive sur ce seul répertoire (millisecondes) suffit à calculer le delta exact et à le propager.
> **Décision proposée** : appliquer les changements **par répertoire, en deltas propagés**, avec le re-scan de sous-arbre actuel (SPEC-02) réservé aux cas dégradés. Corollaire produit : les changements ponctuels peuvent s'**auto-appliquer** — la carte devient un tableau de bord *vivant* qui respire par morphs (SPEC-10), et le bouton Refresh ne subsiste que pour les fallbacks.
> **Dépendances** : PR #26 (bandeau honnête pendant refresh), SPEC-10 mergée (ε-revalidation locale + morphs — le treemap absorbe déjà des updates incrémentaux avec grâce).
> **Statut** : 📋 **PROPOSÉ**.

## 1. Objectif

Qu'un changement ponctuel du disque (fichier créé/supprimé/retaillé, dossier ajouté) soit **visible dans la carte en < 1 s** — mesuré contre les 25 s actuelles sur le scénario du 2026-07-12 — sans re-scan massif, avec des agrégats exacts (tailles, comptes) et un bandeau qui annonce des octets **réellement mesurés** plutôt qu'un delta statfs bruité.

## 2. État actuel du code (vérifié)

- [FSWatcher](../Sources/SpaceMatters/Scanner/FSWatcher.swift#L5) : FSEvents en granularité **répertoire** (pas de `FileEvents`), latence/coalescence 1 s, livraison sur queue privée. **Ne transmet pas les flags d'événements** (`MustScanSubDirs`, `Renamed`…) — première brique à poser.
- [handleDiskChanges](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1109) : chemin → nœud existant le plus proche → `dirtyPaths` ; bandeau gate-é par le budget sur le delta statfs. Depuis PR #26 : muet pendant un refresh en vol.
- [invalidate(subtree:)](../Sources/SpaceMatters/ViewModel/ScanController.swift#L970) : re-scan complet du sous-arbre (epoch + `structuralOpActive` + ancêtres retenus), réconciliation File-types **bornée à 100 k fichiers** (PR #26). C'est le futur **fallback**, pas le chemin nominal.
- `FSNode` : agrégats **atomiques** (`aggLogical/aggPhysical/fileCount`, `directFilesSize/directFileCount`, `dominantExt`) — **pas d'inventaire par fichier en mémoire** (design low-RAM). Les listings existent seulement dans le `fileCache` LRU des dossiers consultés.
- La **propagation de deltas par la chaîne d'ancêtres existe déjà** (`wrappingAdd` — chemins suppression et invalidate) ; idem le détachement de sous-arbre (`applyDirectoryRemoval`).
- Côté rendu, SPEC-10 fait le travail : bump de version → ε-revalidation **locale** des entrées touchées → morph. Un delta ponctuel ne re-roule rien.

## 3. Conception

### 3.1 FSWatcher : transmettre les flags
Le handler reçoit `[(path, flags)]`. Flags exploités : `kFSEventStreamEventFlagMustScanSubDirs` (perte de détail — fallback sous-arbre), `…Renamed` (traité comme paire disparition/apparition au niveau du parent), `…RootChanged`. Latence 1 s conservée (c'est notre coalescence naturelle).

### 3.2 Application d'un événement répertoire `P` (chemin nominal)
1. **Re-stat non récursif** de `P` : une passe du primitif existant ([FSAttr.enumerateDirectory](../Sources/SpaceMatters/Scanner/FSAttr.swift)) → nouveaux `directFilesSize/directFileCount/dominantExt` + **set des sous-dossiers directs**.
2. **Delta fichiers directs** = nouveau − ancien (les agrégats du nœud suffisent — pas besoin d'inventaire par fichier pour tailles/comptes) → propagation `wrappingAdd` jusqu'à la racine. Le treemap voit le bump et morphe.
3. **Diff des sous-dossiers** : apparu → mini-scan `DirectoryScanner` du seul nouveau sous-arbre, rattaché à `P` (c'est le sous-scan d'`invalidate`, à échelle d'un dossier neuf, généralement minuscule) ; disparu → soustraction de ses agrégats + détachement (plomberie `applyDirectoryRemoval`).
4. **File-types** : diff **exact** par extension quand `fileCache` détient l'ancien listing de `P` (et le re-stat devient l'occasion de le rafraîchir) ; sinon best-effort — la même classe de compromis, déjà documentée, que PR #26. Plus de walk récursif nulle part sur ce chemin.
5. **Invariants de sûreté** inchangés : epoch, `structuralOpActive` (un delta ne s'applique jamais pendant une suppression/un rescan), ancêtres retenus pendant toute suspension.

### 3.3 Fallbacks (l'actuel devient le filet)
Bascule vers le marquage sale + Refresh manuel d'aujourd'hui quand :
- `MustScanSubDirs` (FSEvents avoue avoir coalescé/perdu) ;
- **tempête d'événements** : > N répertoires distincts par tick (budget, N≈64) ou file en retard — on marque, bandeau, l'utilisateur décide ;
- chemin qui ne se mappe plus (dossier inconnu de l'arbre, course avec un rename) ;
- ⚖️ **mode Exact** : un fichier hardlinké apparu ne peut pas être déduppé sans l'état `seenInodes` du scan — décision à trancher : fallback systématique en Exact (sûr, conservateur) ou delta en attribution locale avec dérive assumée jusqu'au Rescan. Proposition : fallback.

### 3.4 Auto-application : le produit « carte vivante »
Les deltas nominaux (§3.2) sont **appliqués automatiquement** à réception (coalescés à 1 s) — plus de bandeau, plus de bouton : le fichier téléchargé apparaît dans la carte en glissant, la corbeille vidée fait fondre les tuiles. Le bandeau ne s'affiche plus que pour les **fallbacks** (§3.3), avec son Refresh ciblé actuel. `changedBytes` devient la somme des deltas réellement appliqués (exact) ; le statfs reste comme garde-fou de cohérence (drift > budget sans événement correspondant → proposer un Refresh).
⚖️ Produit : offrir un toggle « Live updates » (défaut ON pour les scans hôte) — certains utilisateurs préféreront une carte figée à l'heure du scan.

## 4. Plan d'implémentation — jalons

**M1 (~1,5 j)** — Flags dans FSWatcher ; re-stat single-dir + deltas propagés, déclenché par le Refresh existant (le bouton devient instantané pour les cas nominaux). Fallback inchangé.
**M2 (~1,5 j)** — Sous-dossiers créés/supprimés, renames (paire disparition/apparition), garde-fous epoch/structuralOp sous tests.
**M3 (~1 j)** — Auto-application + rétrogradation du bandeau aux fallbacks ; budget anti-tempête ; toggle produit.
**M4 (~1 j)** — File-types via fileCache ; politique mode Exact ; `changedBytes` exact.

## 5. Vérification

- **Fixtures** (pattern NavigationTests) : créer/supprimer/retailler un fichier dans un dossier scanné → agrégats exacts propagés jusqu'à la racine **sans** sub-scan (compteur d'appels scanner espionnable) ; dossier créé avec contenu → mini-scan du seul sous-arbre ; dossier supprimé → soustraction exacte.
- **Fallbacks** : événement forgé avec `MustScanSubDirs` → marquage sale comme aujourd'hui ; tempête synthétique (> N dirs) → bascule bandeau.
- **Live QA** : rejouer le scénario du 2026-07-12 (`dd` 4 GiB à la racine du home) → apparition dans la carte **< 1 s** après la latence FSEvents, morph à l'appui ; suppression → fonte.
- **Cohérence** : après une salve de deltas, `du -skx` byte-exact vs agrégats (la méthode de vérif des audits) ; drift statfs vs `changedBytes` sous le budget.

## 6. Risques & hypothèses (🔬)

- 🔬 **Sémantique fine des flags FSEvents** sous coalescence agressive (latence 1 s) — à caractériser tôt (M1) sur événements forgés et réels.
- 🔬 **Renames de gros dossiers** : FSEvents signale les deux parents ; la paire doit re-attacher le sous-arbre existant (déplacement) plutôt que soustraire+re-scanner — optimisation possible, fallback correct en attendant.
- 🔬 **APFS** : clones/sparse — le re-stat mesure ce que `getattrlistbulk` rapporte, comme le scan initial (cohérent par construction) ; à vérifier sur fichiers clonés.
- **Exact mode** : cf. ⚖️ §3.3.
- **dominantExt** local : recalculé sur le seul dossier touché — la couleur d'un ancêtre agrégé peut dériver marginalement jusqu'au Rescan (acceptable, cosmétique).

## 7. Effort & périmètre

**~4-6 j** en 4 jalons livrables. **Ne change pas** : le scan initial, le Rescan complet, les scans VM/K8s (hors périmètre — `isHostScan` seulement), le treemap (SPEC-10 absorbe les deltas par construction). **Change** : FSWatcher (flags), ScanController (chemin nominal par deltas + fallbacks), bandeau (rétrogradé aux fallbacks en M3).
