# SPEC-02 — Sub-tree invalidation & re-scan

> **Findings**: B1 (deep fix — the safeguard is already in place), **A6** (types table stale after deletion), A7 (folder counter), J4.4 (delete during scan — gated), D1 (TOCTOU). Refers to D-B/S2 of the plan.
> **Status**: ✅ **IMPLEMENTED** — A6 resolved (deletion path, exact) + `invalidate(subtree:)` building block delivered for SPEC-04.

## 0. Implementation result

- **A6 resolved (exact) — deletion**: `remove(directory:)` walks the sub-tree **before** deletion (`DirectoryScanner.subtreeExtensions(path:)`, an exact mirror of the scan tally: same `ExtKey`, same alloc/logical sizes) and subtracts that contribution from the scanner's `extStats` table (`subtractExtensions`, zeroed entries removed). `remove(file:)` subtracts the file's extension. The File-types panel updates. Test: `deletingSubtreeUpdatesFileTypeTable` (deleted `.mp4` disappear, `.txt` intact).
- **`invalidate(subtree:)` building block** (reused by SPEC-04): **in-place** re-scan of the sub-tree (seed on the node → correct parents), **exact** reconciliation of the ancestor aggregates (old→new delta), of the **dirCount** (A7), and **nav re-resolution by path** (`node(at:)`) since the descendant nodes become fresh objects (no dangling `unowned`). Test: `invalidateReflectsExternalChanges` (external file+folder addition reflected, zoom re-bound by path).
- **Approach = recommended hybrid (§4/§7)**: exact aggregate subtraction retained (avoids re-scanning a potentially huge parent); only `extStats` is corrected by delta.
- **Documented limit (extStats in `invalidate` only)**: for an extension **shared across sub-trees AND modified** within the invalidated sub-tree, the delta is not exact (the original sub-contribution is not stored per node — low-RAM stance assumed §3); error bounded by the change's delta, self-corrected at the next full rescan. **The deletion path (the A6 finding) stays exact** (walk before the change). Sizes/counts/dirCount always exact.
- **B1/A7/J4.4**: already in place, unchanged and still valid. **D1**: bounded by the `!isScanning` gating; live detection → SPEC-04.

## 1. Objective

Replace the **manual surgery** of the aggregates in `remove()` with a **targeted invalidation + re-scan** of the parent directory. Benefits: removes the entire class of fragile accounting (A6 impossible to fix otherwise — see §3), eliminates any residual risk of inconsistency, and provides the **common building block** reused by FSEvents (SPEC-04).

## 2. Current state of the code (verified)

- `remove(directory:)`/`applyDirectoryRemoval` ([ScanController.swift:507+](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L507)): subtracts the aggregates of each ancestor (atomics), moves `zoomRoot`/`selection`/`expanded` up out of the sub-tree (safeguard B1), decrements `dirCount` (A7), detaches the node.
- **What is NOT adjusted**: the scanner's `extStats` (A6). The per-extension breakdown of the deleted sub-tree is **not stored** in the tree (nodes only keep `dominantExt` + aggregates). So subtracting the per-extension contributions of the deleted sub-tree is **infeasible** without re-enumerating.
- The scanner already knows how to scan a sub-tree: `DirectoryScanner(root:, seeds:[Seed(path:node:)])` — a deletion = a new seed on `node.parent`.

## 3. The crux of the problem (A6)

`extStats: [ExtKey: ExtStat]` is **global to the scan**, built by accumulation during the scan. After deletion of a sub-tree, it still contains the bytes/counts of the deleted files. Three ways out:

- **Store the extensions table per node**: unbounded memory cost (the opposite of the "1 node/directory, low-RAM" stance). ❌
- **Re-scan the deleted sub-tree *before* deletion to know its contributions and subtract them**: possible but fragile (double work, race with the scan). ⚠️
- **Invalidation + re-scan of the parent (recommended)**: after a successful deletion, re-scanning the parent directory rebuilds its children **and** re-accumulates `extStats` for that sub-tree. It remains to reconcile with the global table.

## 4. Design axes & tradeoffs

- **Axis A — Consolidate the in-place mutation**: add the `extStats` subtraction. *Cleanly infeasible* (§3). ❌
- **Axis B — Re-scan of the parent, extensions table recomputed globally**: on deletion, (1) detach the node (as today, B1 safeguards retained), (2) relaunch a `DirectoryScanner` seeded on `parent.path` in a **fresh sub-tree**, (3) atomic swap of `parent._children`, (4) **rebuild `extStats` by re-walking the entire remaining tree** (the files are not in memory → disk re-enumeration of the folders, costly) *or* maintain `extStats` as a sum of recomputed per-seed tables.
- **Axis C — Re-scan of the parent + `extStats` maintained per sub-tree**: the scanner keeps `extStats` **per first-level directory** (or per seed), so that invalidating a sub-tree = subtract its sub-table + re-accumulate. More state, but exact O(1) subtraction.

**Recommendation: Axis B, pragmatic variant.** The re-scan of the parent is the true cure for B1/A6/A7. For `extStats`, **mark the "File types" panel as approximate** just after the deletion *and* recompute it via **lazy** re-enumeration of the re-scanned parent (the parent re-scan already re-accumulates the sub-tree's extensions; it suffices to subtract the parent's old contribution known before the re-scan). Key decision documented below.

**`extStats` decision**: before the re-scan, **snapshot the extensions table restricted to the parent's sub-tree** (obtainable via a "dry-run" re-scan pass of the parent, or by subtracting post-re-scan). *The simplest and exact*: the parent re-scan produces its **new** extensions sub-table; we keep an `extStats` **per direct-parent-of-seed node** in order to do `global = Σ sub-tables`. 🔬 to validate: the memory overhead of a sub-table per child-of-seed (bounded by the number of distinct extensions, small).

## 5. Implementation plan

1. `DirectoryScanner`: expose a **sub-tree re-scan** mode — `rescan(node:path:)` that restarts from a single seed, builds a temporary root `FSNode`, and returns `(children, directFiles, extSubtable, dirCount)`.
2. `ScanController.remove(...)`: on disk success → instead of the aggregate surgery, call `invalidate(subtree: node.parent)`.
3. `invalidate(subtree:)`: launches the re-scan (detached, non-blocking), applies on MainActor: swap `_children`, recompute the ancestor aggregates (delta = new − old sub-total), update `extStats` (Σ sub-tables), `dirCount`, re-resolution of `selection`/`zoomRoot` **by path** (not by node identity, since the nodes are fresh — reuse `path(for:)` + a reverse resolution).
4. Keep the B1 safeguards (they become redundant but harmless) during the migration, then remove them.
5. Gating during scan (J4.4): already in place; the invalidation only runs when `phase != .scanning`.

## 6. Verification

- **Tests** (extend `NavigationTests`): after deleting a sub-tree containing `.mp4`, **`extStats` no longer contains the deleted `.mp4`** (locks A6); `dirCount`, aggregates and absence of a dangling node stay correct; `selection`/`zoomRoot` re-resolved by path.
- **Live**: delete `sub2` from the fixture → the "File types" panel loses the `.bin` of `sub2/deep`, total/folders consistent (before/after screenshot).

## 7. Risks & assumptions

- 🔬 Re-resolution of `selection`/`zoomRoot` by path after node swap: requires a transient path→node index.
- 🔬 Cost of re-scanning a very large parent (e.g. deleting a folder in `/` re-scans the whole root): bound it by re-scanning — **the deleted node itself no longer exists**, so we re-scan its parent — potentially huge. Mitigation: only re-scan if the parent has few remaining children, otherwise keep the aggregate subtraction (exact) and invalidate ONLY the sub-tree's `extStats` (hybrid).
- The hybrid choice (aggregates by subtraction + extStats by sub-table) is perhaps the best simplicity/cost tradeoff — to be decided at implementation time.

## 8. Effort & dependencies

**1–2 days.** No upstream dependency. **Unblocks SPEC-04 (FSEvents)** which reuses `invalidate(subtree:)`.
