# SPEC-04 — FSEvents : du snapshot au tableau de bord vivant

> **Findings** : S3 (différenciateur produit), J5.2 (données périmées sans indicateur), J4.5 (« Put Back » invisible), D1 (TOCTOU des suppressions). **Dépend de SPEC-02** (réutilise `invalidate(subtree:)`).
> **Statut** : ✅ **IMPLÉMENTÉ & LIVE-VÉRIFIÉ** (bannière + timestamp capturés dans l'app).

## 0. Résultat d'implémentation

- **`FSWatcher`** ([FSWatcher.swift](../Sources/MacDirStats/Scanner/FSWatcher.swift)) : `FSEventStreamCreate` sur les seed paths, granularité **répertoire** (pas `FileEvents`), débounce `latency` (1 s), livraison sur une **dispatch queue** privée (`kFSEventStreamCreateFlagUseCFTypes | NoDefer`).
- **Cycle de vie** : démarre à la fin du scan (hôte), s'arrête sur `goHome`/nouveau scan/`deinit`.
- **Suivi des sales par chemin** (pas par identité — `invalidate` recrée les nœuds) : `handleDiskChanges` → `nearestNode(toPath:)` **symlink-tolérant** (canonicalisation : FSEvents rapporte `/private/var/…`, bug trouvé et corrigé), `dirtyPaths` + `diskChanged`.
- **UI** : bannière « The disk changed — [Refresh] » (`DiskChangedBanner`), **pastille par ligne** sur les dossiers sales, **« scanned N ago »** dans la barre de stats (J5.2, `TimelineView` 30 s). **Live-vérifié** (bannière + « just now » capturés).
- **Refresh = `invalidate(subtree:)`** (SPEC-02) sur les sous-arbres sales, ancêtres subsumant les descendants (un seul re-scan). **Portée** : seeds hôtes uniquement.
- **D1** : surfacé par la **bannière persistante** (l'utilisateur est prévenu que le disque a changé avant d'agir) plutôt qu'un modal par-suppression — plus simple, moins intrusif ; la suppression reste gatée `!isScanning`.
- **Test** : `fsEventsMarkDirtyAndRefreshCatchesUp` (end-to-end : écriture externe → `diskChanged` → `refreshDirty` → totaux rattrapés).

## 1. Objectif

Pendant qu'un résultat est affiché, observer le disque et **refléter les changements** : badge « le disque a changé », re-scan incrémental des sous-arbres touchés, âge du scan visible. C'est le différenciateur qui manque à tous les WinDirStat-like, et l'architecture (seeds, arbre live, re-scan par nœud de SPEC-02) y est bien prédisposée.

## 2. État actuel (vérifié)

- Aucun `FSEventStream` (grep). L'arbre est un instantané figé ; `path(for:)` reconstruit des chemins depuis un état potentiellement vieux (D1).
- SPEC-02 fournira `invalidate(subtree:)` — la brique de re-scan ciblé.

## 3. Axes & tradeoffs

- **Granularité** : `kFSEventStreamCreateFlagFileEvents` (par fichier, précis, plus d'events) vs par répertoire (coalescé, moins cher). *Recommandé* : par répertoire, latence ~1 s, suffisant pour marquer un sous-arbre sale.
- **Réaction** : re-scan automatique immédiat vs **badge + re-scan sur demande**. *Recommandé* : badge « changé » + re-scan du sous-arbre sale au clic (respecte l'intention, évite le travail intempestif), avec option « auto ».
- **Portée** : les seeds uniquement (host scans ; pas les scans VM/K8s).

## 4. Plan d'implémentation

1. `FSWatcher` : `FSEventStreamCreate` sur `seedPaths`, callback → set de chemins sales (débounce ~1 s), sur un run loop dédié.
2. Mapper chaque chemin sale → nœud le plus proche (index chemin→nœud, cf. SPEC-02) → marquer « dirty ».
3. UI : badge/pastille sur les nœuds sales + bandeau « le disque a changé — [Actualiser] » ; horodatage « scanné il y a N min » dans la barre d'état (J5.2).
4. Actualiser = `invalidate(subtree:)` (SPEC-02) sur les nœuds sales.
5. Avant toute suppression, si la cible est dans un sous-arbre sale → alerte D1 « le disque a changé, relancez ».

## 5. Vérification

- **Live** : scanner la fixture, créer/supprimer un fichier dedans en shell → badge apparaît ; Actualiser → l'arbre reflète le changement.
- **Test** : `FSWatcher` émet bien un event de coalescence pour un chemin touché (test d'intégration bref).

## 6. Risques & hypothèses

- 🔬 Volume d'events sur de gros arbres actifs (caches) : débounce + coalescence indispensables.
- Cohérence avec l'index chemin→nœud de SPEC-02 (dépendance forte).

## 7. Effort & dépendances

**1–2 jours**, après SPEC-02.
