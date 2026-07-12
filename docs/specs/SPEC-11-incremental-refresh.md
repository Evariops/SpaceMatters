# SPEC-11 — Per-directory incremental refresh: the living map

> **Findings** (session 2026-07-12, live QA on a 315 GiB / 3.9 M files volume): a 4 GiB file created **at the root of the home** triggers, on Refresh, a parallel re-scan **of the entire home** — ~25 s (after PR #26, which bounded a single-threaded extensions walk that pushed this same refresh to several **minutes**). Structural cause: FSEvents is only exploited as a *dirty sub-tree marker* ([handleDiskChanges](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L1109) → `nearestNode`), and [refreshDirty](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L1139) → [invalidate(subtree:)](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L970) rebuilds the whole sub-tree. The banner's figure, for its part, is a **global statfs delta** ([volumeFreeBytes](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L1100)) — it also captures the noise from other processes.
> **What we don't exploit**: the precise semantics of FSEvents at directory granularity — an event without `MustScanSubDirs` means "**the direct content of THIS directory** has changed". A non-recursive `getattrlistbulk` pass over that single directory (milliseconds) is enough to compute the exact delta and propagate it.
> **Decision (settled)**: the **live mode is the default**. Changes apply automatically — deltas **per directory, propagated** for precise events; sub-tree re-scan **auto-triggered** (coalesced to the common ancestor) when FSEvents admits a loss of detail. There is **no dormant fallback**: both mechanisms are nominal, each on its own regime. The banner + Refresh button only remain as a **last resort** — an automatic catch-up that would be large enough to warrant the user's consent. The map becomes a *living* dashboard that breathes through morphs (SPEC-10).
> **Dependencies**: PR #26 (honest banner during refresh), SPEC-10 merged (local ε-revalidation + morphs — the treemap already absorbs incremental updates gracefully).
> **Status**: ✅ **IMPLEMENTED** (2026-07-12, branch `spec/11-incremental-refresh`, M1–M4). Measured at scale (955 k files / 55 GB): +512 MiB in a *new* folder → exact totals **0.01 s** after the write finishes; deletion faded in **0.73 s** — no click, no banner. Objective §1 (< 1 s) exceeded.

## 1. Objective

That a one-off disk change (file created/deleted/resized, folder added) be **visible in the map in < 1 s, with no intervention whatsoever** — measured against the current 25 s + one click on the 2026-07-12 scenario — with exact aggregates (sizes, counts). The downloaded file appears sliding in, the emptied trash melts the tiles away; the user no longer "refreshes", they watch.

## 2. Current state of the code (verified)

- [FSWatcher](../../Sources/SpaceMatters/Scanner/FSWatcher.swift#L5): FSEvents at **directory** granularity (no `FileEvents`), 1 s latency/coalescing, delivery on a private queue. **Does not forward event flags** (`MustScanSubDirs`, `Renamed`…) — first brick to lay.
- [handleDiskChanges](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L1109): path → nearest existing node → `dirtyPaths`; banner gated by the budget on the statfs delta. Since PR #26: silent during an in-flight refresh.
- [invalidate(subtree:)](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L970): full re-scan of the sub-tree (epoch + `structuralOpActive` + retained ancestors), File-types reconciliation **bounded to 100 k files** (PR #26). This is the future **fallback**, not the nominal path.
- `FSNode`: **atomic** aggregates (`aggLogical/aggPhysical/fileCount`, `directFilesSize/directFileCount`, `dominantExt`) — **no per-file inventory in memory** (low-RAM design). The listings exist only in the LRU `fileCache` of the visited folders.
- The **delta propagation up the ancestor chain already exists** (`wrappingAdd` — deletion and invalidate paths); likewise the sub-tree detachment (`applyDirectoryRemoval`).
- On the rendering side, SPEC-10 does the work: version bump → **local** ε-revalidation of the touched entries → morph. A one-off delta re-rolls nothing.

## 3. Design

### 3.1 FSWatcher: forward the flags
The handler receives `[(path, flags)]`. At directory granularity (no `FileEvents` — that's our anti-flood), the per-item flags (`ItemRenamed`, `ItemCreated`…) are **never delivered**; the only exploitable ones are `kFSEventStreamEventFlagMustScanSubDirs` (loss of detail → sub-tree catch-up) and `…RootChanged` — which requires `kFSEventStreamCreateFlagWatchRoot` at creation (to be added; root moved/deleted → banner proposing a Rescan). Renames are detected **structurally**: the diff of sub-folders on re-stat of the parent(s) sees a disappearance + an appearance. `IgnoreSelf` deliberately absent: the echo of our own deletions produces a convergent no-op re-stat, and catches up any discrepancy. 1 s latency kept (that's our natural coalescing).

### 3.2 Applying a directory event `P` (nominal path)
All events converge toward a **serialized reconciliation queue** (a single consumer, on the MainActor between suspensions): at any instant at most one structural operation mutates the tree — same discipline as `remove`/`invalidate`, with which it shares `structuralOpActive` (op refused → re-queued, never forgotten).

1. **Non-recursive re-stat** of `P` off the main thread: one pass of the existing primitive ([enumerateDirectory](../../Sources/SpaceMatters/Scanner/FSAttr.swift#L62)) → **absolute totals** (`directFilesSize/directFileCount/dominantExt` + set of direct sub-folders + file listing). Reused buffer, µs–ms per folder.
2. **Delta = absolute − node state, computed at apply time** on the MainActor — never a pre-computed delta (two re-stats in flight on the same folder converge in last-writer-wins instead of applying a stale delta) → `wrappingAdd` propagation up to the root. The treemap sees the bump and morphs.
3. **Diff of sub-folders** (name diff, at apply): appeared → mini-scan `DirectoryScanner` of the sole new sub-tree attached to `P` — respecting `skipPaths`/mount-points **like the initial scan** (otherwise Data firmlink double-counting); disappeared → subtraction of the aggregates + detachment (`applyDirectoryRemoval` plumbing, which already lifts zoom/selection/expansion toward the survivor).
4. **File-types**: **exact** per-extension diff via a **per-folder snapshot** (bounded LRU, ~4096 folders) fed by each re-stat — exact from the second delta on a folder; seeded by `fileCache` when it holds the complete listing (< 2000 items, its bound). Without a prior snapshot: we don't touch the table (marked drift, same class of trade-off as PR #26). A disappeared **leaf** folder whose snapshot is known is subtracted **exactly** (QA case: the watched download that erases itself — zero drift end to end). No more recursive walk anywhere on this path.
5. **Caches**: the listing obtained in 1 refreshes `fileCache` (the outline follows with no I/O); `sortCache` purged (the size ordering may have changed). The per-delta version bumps coalesce naturally per runloop turn (SwiftUI repaints only once per turn) — during a big cycle, the map updates progressively instead of jumping all at once.
6. **Safety invariants** unchanged: epoch re-checked after each suspension, retained ancestors, `structuralOpActive` exclusive.

### 3.3 Automatic catch-up (not a dormant fallback — a second nominal regime)
When FSEvents **admits a loss of detail**, the detail cannot be reconstructed by deltas — the existing sub-tree re-scan ([invalidate(subtree:)](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L970), proven) takes over **automatically**, with no banner or click:
- `MustScanSubDirs` → auto re-scan of the signaled sub-tree;
- **event burst** → coalescing by **common-prefix clustering**, not to the global common ancestor (100 scattered folders have the root as common ancestor — we would re-scan 3.9 M files where 100 re-stats cost ~100 ms): the **dense** groups (≥ K≈16 dirty paths under the same near ancestor — build churn, checkout, rsync) coalesce each toward *its* ancestor in a single parallel pass; the scattered ones remain unit re-stats, capped (~256/cycle, the excess stays queued);
- **per-sub-tree cooldown** (~10 s) between two auto catch-ups of the same node — a build loop churning continuously marks dirty and waits for the next window, instead of re-scanning the same sub-tree every 2 s.

The cases that the initial version of this spec handled as fallback and that **dissolve into the nominal path**:
- unmappable path (unknown folder, race with a rename) → re-stat of the nearest known **parent** (one-level recursion);
- **Exact mode** (settled): delta in **local attribution + drift marker** on the node (tooltip "hardlink dedup to re-verify") — no systematic re-scan; the full Rescan remains the exact re-synchronization point, as today.

### 3.4 The banner: last resort only
A single case makes it appear: an automatic catch-up (§3.3) whose target sub-tree exceeds a **consent threshold** (`fileCount` > ~500 k, i.e. several seconds of re-scan) — there, we ask before burning the CPU, with PR #26's persistent spinner during execution. Below the threshold, everything is silent and living. `changedBytes` becomes the sum of the deltas actually applied (exact); the global statfs is demoted to a coherence guard-rail: `|statfs drift − applied physical deltas| > budget` → propose a Refresh — the sign that something escaped us (writes outside the observed sub-tree on the same volume remain the known false positive, budget 128 MB unchanged).

## 4. Implementation plan — milestones

**M1 (~1.5 days)** — Flags in FSWatcher; single-dir re-stat + propagated deltas, still triggered by the existing Refresh (the button becomes instant for the nominal cases — an observation step before removing the seatbelt).
**M2 (~1.5 days)** — Created/deleted sub-folders, renames (disappearance/appearance pair), unmappable paths via parent re-stat, epoch/structuralOp guard-rails under tests.
**M3 (~1 day)** — **Switch to live by default**: auto-application of deltas, auto-coalesced sub-tree catch-up (`MustScanSubDirs` + bursts), banner reduced to the consent threshold.
**M4 (~1 day)** — File-types via per-folder snapshots (LRU, seeded by `fileCache`); local attribution + drift marker in Exact mode; exact `changedBytes` + statfs guard-rail.

## 5. Verification

- **Fixtures** (NavigationTests pattern): create/delete/resize a file in a scanned folder → exact aggregates propagated up to the root **without** a sub-scan (spy-able scanner call counter); folder created with content → mini-scan of the sole sub-tree; folder deleted → exact subtraction.
- **Auto catch-up**: forged event with `MustScanSubDirs` → auto re-scan of the sub-tree, no banner; synthetic burst (> N dirs) → coalescing to the common ancestor + a single re-scan; giant burst (> consent threshold) → banner, and only the banner.
- **Live QA**: replay the 2026-07-12 scenario (`dd` 4 GiB at the root of the home) → appearance in the map **< 1 s** after the FSEvents latency, **no click**, morph in support; deletion → melt; `npm install` in a repo → a single coalesced, silent catch-up. ✅ *Measured headless at scale (`SM_QA_LIVE=1`, 955 k files): appearance 0.01 s, melt 0.73 s — see `liveReconcileAtScale`.*
- **Coherence**: after a salvo of deltas, `du -skx` byte-exact vs aggregates (the audits' verification method); statfs drift vs `changedBytes` under budget.

## 6. Risks & assumptions (🔬)

- 🔬 **Fine semantics of FSEvents flags** under aggressive coalescing (1 s latency) — to characterize early (M1) on forged and real events. Empirically validated on 2026-07-12: a stream on `/` does deliver the Data paths in **firmlink form** (`/Users/…`), which `nearestNode` already canonicalizes.
- **Renames of large folders**: detected structurally (disappearance + appearance at the parent(s)) → subtract + re-scan: correct but costly for a large renamed folder. The true re-attach would require the folder's inode persisted by `FSNode` (+8 bytes/node) to recognize the sub-tree — lever identified, deferred.
- 🔬 **APFS**: clones/sparse — the re-stat measures what `getattrlistbulk` reports, like the initial scan (coherent by construction); to verify on cloned files.
- **Exact mode**: local attribution + drift marker (settled §3.3) — hardlink dedup is only re-guaranteed at Rescan; to document in the marker's UI.
- 🔬 **Cascading auto catch-ups**: a `MustScanSubDirs` while an auto re-scan is already running — the serialized reconciliation queue + `structuralOpActive` + the per-sub-tree cooldown must absorb it without a re-scan storm (dedicated test).
- 🔬 **Two re-stats in flight on the same folder**: neutralized by construction (absolute totals, delta computed at apply, serialized queue) — dedicated test anyway.
- **dominantExt** local: recomputed on the sole touched folder — the color of an aggregated ancestor may drift marginally until Rescan (acceptable, cosmetic).

## 7. Effort & scope

**~4-6 days** in 4 deliverable milestones. **Does not change**: the initial scan, the full Rescan, the VM/K8s scans (out of scope — `isHostScan` only), the treemap (SPEC-10 absorbs the deltas by construction). **Changes**: FSWatcher (flags), ScanController (per-directory deltas + auto-coalesced catch-up), banner (reduced to the consent threshold in M3 — the default mode is **live, silent, exact**).
