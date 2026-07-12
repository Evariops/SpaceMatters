# SPEC-11 — Refresh incrémental par répertoire : la carte vivante

> **Findings** (session 2026-07-12, QA live sur volume 315 GiB / 3,9 M fichiers) : un fichier de 4 GiB créé **à la racine du home** déclenche, au Refresh, un re-scan parallèle **du home entier** — ~25 s (après PR #26, qui a borné un walk d'extensions mono-thread qui portait ce même refresh à plusieurs **minutes**). Cause structurelle : FSEvents n'est exploité que comme *marqueur de sous-arbre sale* ([handleDiskChanges](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1109) → `nearestNode`), et [refreshDirty](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1139) → [invalidate(subtree:)](../Sources/SpaceMatters/ViewModel/ScanController.swift#L970) reconstruit tout le sous-arbre. Le chiffre du bandeau, lui, est un **delta statfs global** ([volumeFreeBytes](../Sources/SpaceMatters/ViewModel/ScanController.swift#L1100)) — il capte aussi le bruit des autres process.
> **Ce qu'on n'exploite pas** : la sémantique précise de FSEvents en granularité répertoire — un événement sans `MustScanSubDirs` signifie « **le contenu direct de CE répertoire** a changé ». Une passe `getattrlistbulk` non récursive sur ce seul répertoire (millisecondes) suffit à calculer le delta exact et à le propager.
> **Décision (actée)** : le **live est le mode par défaut**. Les changements s'appliquent automatiquement — deltas **par répertoire, propagés** pour les événements précis ; re-scan de sous-arbre **auto-déclenché** (coalescé à l'ancêtre commun) quand FSEvents avoue une perte de détail. Il n'y a **pas de fallback dormant** : les deux mécanismes sont nominaux, chacun sur son régime. Le bandeau + bouton Refresh ne subsistent qu'en **dernier recours** — un rattrapage automatique qui serait assez gros pour mériter le consentement de l'utilisateur. La carte devient un tableau de bord *vivant* qui respire par morphs (SPEC-10).
> **Dépendances** : PR #26 (bandeau honnête pendant refresh), SPEC-10 mergée (ε-revalidation locale + morphs — le treemap absorbe déjà des updates incrémentaux avec grâce).
> **Statut** : 📋 **PROPOSÉ**.

## 1. Objectif

Qu'un changement ponctuel du disque (fichier créé/supprimé/retaillé, dossier ajouté) soit **visible dans la carte en < 1 s, sans aucune intervention** — mesuré contre les 25 s + un clic actuels sur le scénario du 2026-07-12 — avec des agrégats exacts (tailles, comptes). Le fichier téléchargé apparaît en glissant, la corbeille vidée fait fondre les tuiles ; l'utilisateur ne « rafraîchit » plus, il regarde.

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

### 3.3 Rattrapage automatique (pas un fallback dormant — un second régime nominal)
Quand FSEvents **avoue une perte de détail**, le détail ne peut pas être reconstruit par deltas — le re-scan de sous-arbre existant ([invalidate(subtree:)](../Sources/SpaceMatters/ViewModel/ScanController.swift#L970), éprouvé) prend le relais **automatiquement**, sans bandeau ni clic :
- `MustScanSubDirs` → re-scan auto du sous-arbre signalé ;
- **rafale d'événements** (> N≈64 répertoires distincts par tick — churn de build, checkout, rsync) → les chemins sales sont **coalescés à leur ancêtre commun** (la déduplication topmost de `refreshDirty` existe déjà) et ce sous-arbre est re-scanné en une passe parallèle — au-delà d'un seuil de rafale, c'est *plus rapide* que N re-stats unitaires, pas seulement plus sûr.

Les cas que la version initiale de cette spec traitait en fallback et qui **se dissolvent dans le chemin nominal** :
- chemin non mappable (dossier inconnu, course avec un rename) → re-stat du **parent** connu le plus proche (récursion d'un niveau) ;
- **mode Exact** (acté) : delta en **attribution locale + marqueur de dérive** sur le nœud (tooltip « dédup hardlinks à re-vérifier ») — pas de re-scan systématique ; le Rescan complet reste le point de re-synchronisation exacte, comme aujourd'hui.

### 3.4 Le bandeau : dernier recours uniquement
Un seul cas le fait apparaître : un rattrapage automatique (§3.3) dont le sous-arbre coalescé dépasse un **seuil de consentement** (> ~500 k fichiers, soit plusieurs secondes de re-scan) — là, on demande avant de brûler le CPU, avec le spinner persistant de PR #26 pendant l'exécution. En dessous du seuil, tout est silencieux et vivant. `changedBytes` devient la somme des deltas réellement appliqués (exact) ; le statfs global est rétrogradé en garde-fou de cohérence (drift > budget sans événement correspondant → proposer un Refresh — le signe que quelque chose nous a échappé).

## 4. Plan d'implémentation — jalons

**M1 (~1,5 j)** — Flags dans FSWatcher ; re-stat single-dir + deltas propagés, encore déclenché par le Refresh existant (le bouton devient instantané pour les cas nominaux — étape d'observation avant d'ôter la ceinture).
**M2 (~1,5 j)** — Sous-dossiers créés/supprimés, renames (paire disparition/apparition), chemins non mappables via re-stat du parent, garde-fous epoch/structuralOp sous tests.
**M3 (~1 j)** — **Bascule live par défaut** : auto-application des deltas, rattrapage sous-arbre auto-coalescé (`MustScanSubDirs` + rafales), bandeau réduit au seuil de consentement.
**M4 (~1 j)** — File-types via fileCache ; attribution locale + marqueur de dérive en mode Exact ; `changedBytes` exact.

## 5. Vérification

- **Fixtures** (pattern NavigationTests) : créer/supprimer/retailler un fichier dans un dossier scanné → agrégats exacts propagés jusqu'à la racine **sans** sub-scan (compteur d'appels scanner espionnable) ; dossier créé avec contenu → mini-scan du seul sous-arbre ; dossier supprimé → soustraction exacte.
- **Rattrapage auto** : événement forgé avec `MustScanSubDirs` → re-scan auto du sous-arbre, sans bandeau ; rafale synthétique (> N dirs) → coalescence à l'ancêtre commun + un seul re-scan ; rafale géante (> seuil de consentement) → bandeau, et lui seul.
- **Live QA** : rejouer le scénario du 2026-07-12 (`dd` 4 GiB à la racine du home) → apparition dans la carte **< 1 s** après la latence FSEvents, **sans clic**, morph à l'appui ; suppression → fonte ; `npm install` dans un repo → un seul rattrapage coalescé, silencieux.
- **Cohérence** : après une salve de deltas, `du -skx` byte-exact vs agrégats (la méthode de vérif des audits) ; drift statfs vs `changedBytes` sous le budget.

## 6. Risques & hypothèses (🔬)

- 🔬 **Sémantique fine des flags FSEvents** sous coalescence agressive (latence 1 s) — à caractériser tôt (M1) sur événements forgés et réels.
- 🔬 **Renames de gros dossiers** : FSEvents signale les deux parents ; la paire doit re-attacher le sous-arbre existant (déplacement) plutôt que soustraire+re-scanner — optimisation possible, fallback correct en attendant.
- 🔬 **APFS** : clones/sparse — le re-stat mesure ce que `getattrlistbulk` rapporte, comme le scan initial (cohérent par construction) ; à vérifier sur fichiers clonés.
- **Exact mode** : attribution locale + marqueur de dérive (acté §3.3) — la dédup hardlinks n'est re-garantie qu'au Rescan ; à documenter dans l'UI du marqueur.
- 🔬 **Rattrapages auto en cascade** : un `MustScanSubDirs` pendant qu'un re-scan auto tourne déjà — la sérialisation par `structuralOpActive` + la file de chemins sales doivent absorber sans tempête de re-scans (test dédié).
- **dominantExt** local : recalculé sur le seul dossier touché — la couleur d'un ancêtre agrégé peut dériver marginalement jusqu'au Rescan (acceptable, cosmétique).

## 7. Effort & périmètre

**~4-6 j** en 4 jalons livrables. **Ne change pas** : le scan initial, le Rescan complet, les scans VM/K8s (hors périmètre — `isHostScan` seulement), le treemap (SPEC-10 absorbe les deltas par construction). **Change** : FSWatcher (flags), ScanController (deltas par répertoire + rattrapage auto-coalescé), bandeau (réduit au seuil de consentement en M3 — le mode par défaut est **live, silencieux, exact**).
