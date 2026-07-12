# SPEC-05 — File-level refinement on zoom (per-folder overview)

> **Findings**: S5 (README mentions it), complements A8 (tile color). Optional.
> **Product constraint (imposed)**: the **overview stays strictly per folder** — legibility takes priority. File-level detail is a property of the **current zoom level**, never of the whole map.
> **Status**: ✅ **IMPLEMENTED & LIVE-VERIFIED** (Axis B2 — file-tiles at zoomRoot, sub-folders aggregated).

## 0. Implementation result

- **Axis B2**: `TreemapLayout.compute(..., rootFiles:)` — only the direct files of the **zoomRoot** (depth 0) are materialized as individual tiles; the sub-folders stay aggregated (recursion with `files: nil`). The overview stays strictly per folder.
- **`TreemapTile.file: FileTileInfo?`** (name, size at the current metric, extension) carries the file-tile; color by **file extension** (`treemapTypeColor`, consistent with the legend), label = file name, dedicated hover/menu/double-click (Open/Reveal/Copy). **Live-verified**: `demo05` shows video.mp4/archive.zip/photo.png/document.pdf/notes.txt as distinct colored tiles, `subfolder` aggregated.
- **Residual**: if the file list is capped (`maxFilesPerFolder`), the remainder stays an aggregated "other files" block (exact proportions).
- **Memory**: the files come from the existing **bounded** `fileCache` (≤ 2000/folder, per visited directory), filled on zoom-in via `filesIn(zoomRoot)`. Not materialized **during** the scan (avoids re-enumeration at 10 Hz) — refinement once the scan has stabilized.
- **Test**: `zoomRootRefinesIntoFileTiles` (zoomRoot → N file-tiles + aggregated sub-folder; overview → 1 aggregated block, 0 file-tile).

## 1. Objective

When you **enter a folder** (click/double-click/zoom), that folder's region **refines down to the files**; conversely, the overview displays **only folders**. File-tiles are never scattered across the whole map: global legibility comes first.

## 2. Current state (verified)

- "1 node/directory" model ([FSNode.swift](../../Sources/SpaceMatters/Model/FSNode.swift)): files are not objects; aggregated into `directFiles*`.
- The treemap renders the sub-tree of `zoomRoot` ([TreemapView.swift](../../Sources/SpaceMatters/Views/TreemapView.swift)); the zoom (tile double-click, breadcrumb, ⌘↑) exists and works.
- Today, inside a zoomed folder, sub-folders are tiles but the **direct files are aggregated** into a single leaf-tile (color = direct dominant, cf. A8). On-demand enumeration: `filesIn` ([ScanController.swift:344](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L344)), not persisted.

## 3. Design principle

- **Overview level** (`zoomRoot` = scan root, or any "from afar" level): tiles **per folder** only — current behavior **preserved**.
- **Entering a folder** (`zoomRoot` = that folder): the map displays the **direct files** of that folder as individual tiles, interleaved with its sub-folders (still aggregated).
- **Zoom-out**: return to the per-folder aggregate; the file memory of the folder left is **freed**.

→ The refinement follows the **zoom**, not a global threshold. This is what guarantees a legible overview.

## 4. Axes & tradeoffs

- **Axis A — Global size threshold** (show files everywhere they exceed the tile threshold): **rejected** — would scatter files into the overview, contrary to the product constraint. ❌
- **Axis B — Zoom-driven refinement (recommended)**: materialize file-tiles **only for the current `zoomRoot`**. Overview untouched, memory bounded to the open folder.
  - **B1**: files of the `zoomRoot` **and** of its 1st-level sub-folders (one notch of refinement — richer, a bit denser).
  - **B2**: direct files of the `zoomRoot` only; the sub-folders stay aggregated tiles until you enter them (more conservative, the most legible). **Recommended default.**
- **Storage**: compact columnar blob per refined directory `[(nameOffset: UInt32, logical: Int64, physical: Int64, extIndex)]` + name arena (~24 B/file), **filled on zoom-in, emptied on zoom-out**.

**Recommended: Axis B / B2**, toggleable via a "file detail" toggle (default on), with the option to switch to B1.

## 5. Implementation plan

1. Compact (columnar) `FileBlock` built on the fly for the `zoomRoot` when you enter it (reuses the enumeration of `filesIn`, but persisted compactly).
2. `TreemapLayout.compute`: if the rendered node **is the `zoomRoot`** (B2) and has a `FileBlock`, subdivide its region into file-tiles (squarify of the file sizes) instead of a single leaf-tile. Beyond this level → per-folder aggregate unchanged.
3. Memory life cycle: fill in `zoom(into:)`, free in `zoomOut`/`resetZoom`/`navigate` when leaving the folder (strict bound: at most the file content of one folder at a time, +1 level if B1).
4. Hit-test / hover / selection at file level **only in the refined zone**; elsewhere, current node behavior.
5. Color per file via `ExtKey`/palette (already consistent with the legend). Take advantage of the pass for A8 (weighted dominant of the sub-tree on the aggregated folder-tiles).

## 6. Verification

- **Live (established method)**: overview → **folder** tiles (screenshot, legible); zoom into `sub1` → files of `sub1` as individual tiles (screenshot); ⌘↑ → return to the folder aggregate. Verify that at the overview **no** file-tile appears.
- **Test**: `FileBlock` round-trip (names/sizes/ext); budget ≤ 24 B/file; freeing on zoom-out.

## 7. Risks & assumptions

- 🔬 Visual transition zoom-in/out (appearance/disappearance of file-tiles): animate or switch cleanly on relayout (`recompute`).
- B1 vs B2 choice to calibrate on real folders (density vs richness).
- Interaction with the hit-test that today reasons in nodes: introduce a distinct "file" tile type.

## 8. Effort & dependencies

**2–3 days.** Independent (synergy A8). The zoom-driven approach reuses the existing `zoomRoot` infrastructure.
