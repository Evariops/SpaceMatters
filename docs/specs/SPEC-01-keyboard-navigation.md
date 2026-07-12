# SPEC-01 — Keyboard navigation & native list

> **Findings**: J3.1 (100% mouse-driven app), J4.2 (no ⌘⌫ nor multi-selection), partially J3.7 (sorting/columns). Refers to D-E of the plan.
> **Status**: ✅ **IMPLEMENTED** (Axis B — `NSTableView` as `NSViewRepresentable`). See [DirectoryTable.swift](../../Sources/SpaceMatters/Views/DirectoryTable.swift).

## 0. Implementation result

- `DirectoryTable: NSViewRepresentable` (NSScrollView + `MacDirTableView`), rows = `NSHostingView(OutlineRowView)` → **zero visual regression** (SwiftUI rendering reused as-is).
- **Deterministic** mouse: `MacDirTableView.hitTest` returns the table for any in-bounds point (purely visual cells); selection goes through `NSTableView.mouseDown`/`row(at:)`, not through responder-chain forwarding. Collapse/expand chevron by geometry in `mouseDown`.
- Keyboard: ↑/↓ native, ←/→ collapse/parent & expand/child, ⏎ zoom/open, **⌘⌫ trash the selection (gated on `!isScanning`)**, space Quick Look, native type-select.
- **Multi-selection** (`allowsMultipleSelection`): `ScanController.selectedRowIDs` (set) + `setListSelection(_:primary:)` — the *primary* drives the treemap, the set drives ⌘⌫. Per-row context menu (Quick Look/Open/Reveal/Copy/Trash/Delete) via `menu(for:)`.
- treemap↔list sync: `selectedRowID` remains the single source; `updateNSView` idempotent, `scrollRowToVisible` on `revealTarget`.
- **Verified**: green build; 12 tests (including `listSelectionTracksPrimaryAndSet`, `deletingAncestorClearsStaleMultiSelection`); **live** — the native table renders the outline with full fidelity (chevrons/icons/bars/sizes/sorting), selection drawn, **each row exposed to AX** with a label ("Folder alpha, 1000 KB"), no crash. Driving via synthesized events (click/arrows) was blocked by a *Secure Event Input* panel from another app; logic covered by the ViewModel tests.
- **Remaining optional (outside the 100% scope)**: J3.7 sortable column headers — explicitly "optional" in §5.7. Multi-target context menu (today ⌘⌫ covers bulk trashing).

## 1. Objective

Make the directory list keyboard-drivable for the target user (senior dev): ↑/↓ arrows to move through it, ←/→ to collapse/expand, ⏎ to zoom/open, ⌘⌫ to move to trash, space bar for QuickLook, multi-selection (⇧/⌘-click) for bulk cleanup, and type-select (typing a prefix).

## 2. Current state of the code (verified)

- [DirectoryListView.swift](../../Sources/SpaceMatters/Views/DirectoryListView.swift): `List { ForEach(rows) { OutlineRowView… } }`, `listStyle(.plain)`, custom rows. Selection via `.onTapGesture { select() }`, zoom via `.simultaneousGesture(TapGesture(count: 2))`, chevron via a dedicated `.onTapGesture`, `.contextMenu`. The selection is `controller.selectedRowID` (derives `selection`).
- `visibleRows()` ([ScanController.swift:398](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L398)) produces a **flat array** (dirs + files interleaved, biggest-first) — already the right model for a table.
- Zoom/selection/expansion are centralized in `ScanController` (good).

## 3. Lesson learned (verified live)

`List(selection:)` + `.tag(row.id)` was tried and **driven on screen**:
- the `List` does **not** take keyboard focus (arrows inert);
- native selection does **not** engage on single click as long as the rows carry their own `onTapGesture`/`contentShape`/double-click;
- removing the `onTapGesture` **breaks** single-click without unblocking the arrows.

→ Keyboard navigation **is not a bolt-on** on the current SwiftUI `List`.

## 4. Design axes & tradeoffs

- **Axis A — All-SwiftUI `List(selection:)`**: strip the rows of all their gestures, let the `List` own the selection, re-add chevron/double-click/hover some other way. *Tradeoff*: fights SwiftUI focus quirks (observed), native selection rendering to re-style, arrow behavior not guaranteed on a `List` with custom content. **High risk, uncertain outcome.**
- **Axis B — `NSViewRepresentable` around an `NSTableView` (recommended)**: **deterministic** control of the keyboard (arrows, ⌘⌫, type-select, multi-select), focus (first responder), selection, and scrolling. This is how dense Mac apps (Finder-like) do it. *Tradeoff*: more code (≈250–350 lines), a SwiftUI↔AppKit bridge to maintain. *Benefit*: robust, testable, extensible (sortable columns J3.7, multi-selection J4.2 for free).
- **Axis C — `NSOutlineView`**: handles the tree natively (disclosure), but we already have a *flat* model (`visibleRows()`) and expansion lives in the controller → `NSTableView` fits better, less friction.

**Recommendation: Axis B.** An `NSTableView` as `NSViewRepresentable`, fed by `visibleRows()`, cells rendered via `NSHostingView(OutlineRowView)` to **reuse the existing SwiftUI design** (zero visual regression). Keyboard/focus/multi-selection become native and reliable.

## 5. Implementation plan

1. **`DirectoryTable: NSViewRepresentable`** producing `NSScrollView` + `NSTableView` (one column, fixed `rowHeight`, `usesAlternatingRowBackgroundColors = false`, plain style).
2. **Data source / delegate** (`Coordinator`): rows = `controller.visibleRows()`; `numberOfRows`, `viewFor:` → `NSHostingView(rootView: OutlineRowView(row:…))` reused (pooled via `makeView(withIdentifier:)`).
3. **Selection**: `allowsMultipleSelection = true`. `tableViewSelectionDidChange` → push to `controller.selectedRowID`/`selection`; conversely, `updateNSView` re-selects when `controller.selectedRowID` changes (breadcrumb/treemap → list).
4. **Keyboard** (subclass `NSTableView.keyDown` or `NSResponder`):
   - ↑/↓: native.
   - ←/→: collapse/expand the selected folder row (`controller.toggleExpanded`).
   - ⏎: `controller.zoom(into:)` (folder) / `openItem` (file).
   - ⌘⌫: trash the selected row(s), **gated on `!isScanning`** (J4.4), via the existing async `remove(...)` flow.
   - space: QuickLook of the selected URLs.
   - type-select: native via `tableView(_:typeSelectStringFor:)`.
5. **Multi-selection → bulk actions**: `controller.remove(rows:)` iterating the async flow; equivalent `contextMenu(forSelectionType:)` context menu.
6. Replace `List{…}` with `DirectoryTable(controller:)` in `DirectoryListView`. Keep `revealTarget`/scroll-to (via `scrollRowToVisible`).
7. Optional (J3.7): sortable column headers (name / size / file count / date) → `sortDescriptors` → new sort in the controller.

## 6. Verification

- **Live (established method)**: `--open <fixture>`, screenshot, `key code 125/126` (↓/↑) → the selection moves (verifiable by the highlight); ⌘⌫ on a row → trash + total decremented; ⇧-click → multi-selection; space → QuickLook panel.
- **ViewModel tests**: `controller.selectRow`, multi-remove, gating during scan (extend `NavigationTests`).

## 7. Risks & assumptions

- 🔬 **Per-row `NSHostingView` perf** on a very large list: mitigate via view reuse + a lightweight `OutlineRowView`; to be measured on a folder with 100k visible rows (rare — the list is virtualized to O(visible)).
- 🔬 Bidirectional list-selection ↔ treemap synchronization without an event loop: keep `selectedRowID` as the single source, `updateNSView` idempotent.
- Focus ring / selection appearance to match the theme (draw the selection in `OutlineRowView` via `isSelected`, disable the AppKit-drawn selection).

## 8. Effort & dependencies

**1–2 days.** No dependencies. Unblocks J3.1, J4.2, and paves the way for J3.7 (columns) and part of SPEC-08 (natively accessible focus/rotor).
