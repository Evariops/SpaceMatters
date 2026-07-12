# SPEC-04 — FSEvents: from snapshot to live dashboard

> **Findings**: S3 (product differentiator), J5.2 (stale data with no indicator), J4.5 ("Put Back" invisible), D1 (deletion TOCTOU). **Depends on SPEC-02** (reuses `invalidate(subtree:)`).
> **Status**: ✅ **IMPLEMENTED & LIVE-VERIFIED** (banner + timestamp captured in the app).

## 0. Implementation result

- **`FSWatcher`** ([FSWatcher.swift](../../Sources/SpaceMatters/Scanner/FSWatcher.swift)): `FSEventStreamCreate` on the seed paths, **directory** granularity (not `FileEvents`), `latency` debounce (1 s), delivery on a private **dispatch queue** (`kFSEventStreamCreateFlagUseCFTypes | NoDefer`).
- **Lifecycle**: starts at the end of the scan (host), stops on `goHome`/new scan/`deinit`.
- **Dirty tracking by path** (not by identity — `invalidate` recreates the nodes): `handleDiskChanges` → `nearestNode(toPath:)` **symlink-tolerant** (canonicalization: FSEvents reports `/private/var/…`, bug found and fixed), `dirtyPaths` + `diskChanged`.
- **UI**: "The disk changed — [Refresh]" banner (`DiskChangedBanner`), **per-row dot** on dirty folders, **"scanned N ago"** in the stats bar (J5.2, `TimelineView` 30 s). **Live-verified** (banner + "just now" captured).
- **Refresh = `invalidate(subtree:)`** (SPEC-02) on the dirty sub-trees, ancestors subsuming descendants (a single re-scan). **Scope**: host seeds only.
- **D1**: surfaced by the **persistent banner** (the user is warned that the disk changed before acting) rather than a per-deletion modal — simpler, less intrusive; deletion stays gated on `!isScanning`.
- **Test**: `fsEventsMarkDirtyAndRefreshCatchesUp` (end-to-end: external write → `diskChanged` → `refreshDirty` → totals caught up).

## 1. Objective

While a result is displayed, watch the disk and **reflect the changes**: "the disk changed" badge, incremental re-scan of the affected sub-trees, visible scan age. This is the differentiator that all WinDirStat-likes lack, and the architecture (seeds, live tree, per-node re-scan from SPEC-02) is well predisposed to it.

## 2. Current state (verified)

- No `FSEventStream` (grep). The tree is a frozen snapshot; `path(for:)` reconstructs paths from a potentially old state (D1).
- SPEC-02 will provide `invalidate(subtree:)` — the targeted re-scan building block.

## 3. Axes & tradeoffs

- **Granularity**: `kFSEventStreamCreateFlagFileEvents` (per file, precise, more events) vs per directory (coalesced, cheaper). *Recommended*: per directory, ~1 s latency, sufficient to mark a sub-tree dirty.
- **Reaction**: immediate automatic re-scan vs **badge + re-scan on demand**. *Recommended*: "changed" badge + re-scan of the dirty sub-tree on click (respects the intent, avoids untimely work), with an "auto" option.
- **Scope**: the seeds only (host scans; not VM/K8s scans).

## 4. Implementation plan

1. `FSWatcher`: `FSEventStreamCreate` on `seedPaths`, callback → set of dirty paths (~1 s debounce), on a dedicated run loop.
2. Map each dirty path → nearest node (path→node index, cf. SPEC-02) → mark "dirty".
3. UI: badge/dot on dirty nodes + "the disk changed — [Refresh]" banner; "scanned N min ago" timestamp in the status bar (J5.2).
4. Refresh = `invalidate(subtree:)` (SPEC-02) on the dirty nodes.
5. Before any deletion, if the target is in a dirty sub-tree → D1 alert "the disk changed, re-run".

## 5. Verification

- **Live**: scan the fixture, create/delete a file in it via shell → badge appears; Refresh → the tree reflects the change.
- **Test**: `FSWatcher` does emit a coalescing event for a touched path (short integration test).

## 6. Risks & assumptions

- 🔬 Event volume on large active trees (caches): debounce + coalescing indispensable.
- Consistency with the SPEC-02 path→node index (strong dependency).

## 7. Effort & dependencies

**1–2 days**, after SPEC-02.
