import SwiftUI
import AppKit

/// The directory outline, backed by a native `NSTableView`.
///
/// Why AppKit and not SwiftUI's `List`: keyboard navigation (arrows, ←/→ to
/// fold, ⏎ to open, ⌘⌫ to trash, type-select), multi-selection and reliable
/// first-responder focus are *deterministic* on `NSTableView` and were found not
/// to be a bolt-on onto a `List` with custom-content rows (see SPEC-01). The row
/// visuals are still the existing SwiftUI `OutlineRowView`, hosted per row, so
/// there's zero visual regression — only the container changed.
struct DirectoryTable: NSViewRepresentable {
    let controller: ScanController
    let rows: [ScanController.OutlineRow]
    let theme: Theme
    /// Bumps whenever the controller refreshes, so live sizes repaint.
    let version: UInt64
    let requestDelete: (ScanController.OutlineRow) -> Void
    let reportError: (String) -> Void
    let quickLook: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, theme: theme,
                    requestDelete: requestDelete, reportError: reportError, quickLook: quickLook)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator

        let table = MacDirTableView()
        table.coord = coord
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none // OutlineRowView draws its own selection
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = []
        table.dataSource = coord
        table.delegate = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.tableDoubleClicked)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        coord.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        coord.update(rows: rows) // initial fill
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.controller = controller
        coord.theme = theme
        coord.requestDelete = requestDelete
        coord.reportError = reportError
        coord.quickLook = quickLook
        coord.update(rows: rows)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var controller: ScanController
        var theme: Theme
        var requestDelete: (ScanController.OutlineRow) -> Void
        var reportError: (String) -> Void
        var quickLook: (URL) -> Void

        weak var table: MacDirTableView?
        private(set) var rows: [ScanController.OutlineRow] = []
        private var rowIDs: [ScanController.RowID] = []
        private var rowIndexByID: [ScanController.RowID: Int] = [:]
        /// Suppress delegate → controller pushes while *we* mutate the selection.
        private var applyingSelection = false
        private var hoveredRow = -1

        init(controller: ScanController, theme: Theme,
             requestDelete: @escaping (ScanController.OutlineRow) -> Void,
             reportError: @escaping (String) -> Void,
             quickLook: @escaping (URL) -> Void) {
            self.controller = controller
            self.theme = theme
            self.requestDelete = requestDelete
            self.reportError = reportError
            self.quickLook = quickLook
        }

        // MARK: Refresh

        func update(rows newRows: [ScanController.OutlineRow]) {
            guard let table else { return }
            let newIDs = newRows.map(\.id)
            let structureChanged = newIDs != rowIDs
            rows = newRows
            rowIDs = newIDs
            if structureChanged {
                // O(1) id→row projection for selection sync and reveal-scroll: a
                // linear firstIndex per selected id turns ⌘A on a big list into
                // O(N²) per update.
                rowIndexByID = Dictionary(newIDs.enumerated().map { ($1, $0) },
                                          uniquingKeysWith: { first, _ in first })
            }

            applyingSelection = true
            if structureChanged {
                table.reloadData()
            } else {
                refreshVisibleCells()
            }
            applySelectionFromController()
            applyingSelection = false

            scrollToRevealTargetIfNeeded()
        }

        private func refreshVisibleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for r in visible.location..<(visible.location + visible.length) where r >= 0 && r < rows.count {
                if let cell = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? DirectoryRowCell {
                    cell.configure(makeRowView(r))
                }
            }
        }

        private func applySelectionFromController() {
            guard let table else { return }
            let want = IndexSet(controller.selectedRowIDs.compactMap { rowIndexByID[$0] })
            if table.selectedRowIndexes != want {
                table.selectRowIndexes(want, byExtendingSelection: false)
            }
        }

        private func scrollToRevealTargetIfNeeded() {
            guard let target = controller.revealTarget, let table else { return }
            if let idx = rowIndexByID[.dir(ObjectIdentifier(target))] {
                table.scrollRowToVisible(idx)
            }
            // Clear async to avoid mutating observable state during a view update.
            DispatchQueue.main.async { [weak controller] in controller?.revealTarget = nil }
        }

        func makeRowView(_ index: Int) -> OutlineRowView {
            let row = rows[index]
            let isDirty: Bool
            if case .directory(let node) = row.kind { isDirty = controller.isDirty(node) } else { isDirty = false }
            return OutlineRowView(
                row: row,
                isSelected: controller.selectedRowIDs.contains(row.id),
                isHovered: index == hoveredRow,
                isDirty: isDirty,
                metric: controller.metric,
                controller: controller,
                theme: theme
            )
        }

        // MARK: Hover

        func setHovered(_ row: Int) {
            guard row != hoveredRow else { return }
            let old = hoveredRow
            hoveredRow = row
            reconfigure(old)
            reconfigure(row)
        }

        private func reconfigure(_ index: Int) {
            guard let table, index >= 0, index < rows.count,
                  let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? DirectoryRowCell
            else { return }
            cell.configure(makeRowView(index))
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("DirectoryRowCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DirectoryRowCell)
                ?? { let c = DirectoryRowCell(); c.identifier = id; return c }()
            cell.configure(makeRowView(row))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let idxs = table.selectedRowIndexes.filter { $0 >= 0 && $0 < rows.count }
            let ids = Set(idxs.map { rowIDs[$0] })
            let primaryIdx = (table.selectedRow >= 0 && table.selectedRow < rows.count)
                ? table.selectedRow : idxs.first
            controller.setListSelection(ids, primary: primaryIdx.map { rows[$0] })
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard row >= 0 && row < rows.count else { return nil }
            return Self.displayName(rows[row])
        }

        // MARK: Actions

        @objc func tableDoubleClicked() { activatePrimary() }

        func activatePrimary() {
            guard let row = primaryRow() else { return }
            switch row.kind {
            case .directory(let node):
                controller.zoom(into: node)
            case .file(let file, let parent):
                if let path = controller.path(forFile: file, parent: parent) { controller.openItem(path) }
            }
        }

        /// ⌘⌫ → move the whole selection to the Trash (reversible; no confirm).
        /// Gated while scanning (J4.4): deleting mid-scan would corrupt totals.
        func trashSelection() {
            guard controller.isHostScan else { return }
            guard !controller.isScanning else { NSSound.beep(); return }
            let targets = selectedRows()
            guard !targets.isEmpty else { return }
            Task { @MainActor in
                var failed: [String] = []
                for row in targets {
                    let ok: Bool
                    switch row.kind {
                    case .directory(let node): ok = await controller.remove(directory: node, permanently: false)
                    case .file(let f, let parent): ok = await controller.remove(file: f, parent: parent, permanently: false)
                    }
                    if !ok { failed.append(Self.displayName(row)) }
                }
                if !failed.isEmpty {
                    let list = failed.prefix(3).joined(separator: ", ")
                    reportError("Couldn't move \(failed.count == 1 ? "“\(list)”" : "\(failed.count) items (\(list)…)") to the Trash.")
                }
            }
        }

        func quickLookSelection() {
            guard controller.isHostScan, let row = primaryRow() else { return }
            let path: String?
            switch row.kind {
            case .directory(let node): path = controller.path(for: node)
            case .file(let file, let parent): path = controller.path(forFile: file, parent: parent)
            }
            if let path { quickLook(URL(fileURLWithPath: path)) }
        }

        /// Left arrow: collapse if expanded, else jump to parent row.
        func handleLeftArrow() -> Bool {
            guard let idx = primaryIndex() else { return false }
            let r = rows[idx]
            if case .directory(let node) = r.kind, r.isExpandable, controller.isExpanded(node) {
                controller.toggleExpanded(node)
                return true
            }
            let depth = r.depth
            var j = idx - 1
            while j >= 0 {
                if rows[j].depth < depth { select(index: j); return true }
                j -= 1
            }
            return true
        }

        /// Right arrow: expand if collapsed, else step into the first child.
        func handleRightArrow() -> Bool {
            guard let idx = primaryIndex() else { return false }
            let r = rows[idx]
            if case .directory(let node) = r.kind, r.isExpandable {
                if !controller.isExpanded(node) { controller.toggleExpanded(node); return true }
            }
            if idx + 1 < rows.count { select(index: idx + 1) }
            return true
        }

        /// Click landed on a disclosure chevron → toggle instead of just selecting.
        /// Mirrors `OutlineRowView`'s leading padding + chevron geometry.
        func handleChevronClick(row: Int, pointX: CGFloat) -> Bool {
            guard row >= 0, row < rows.count else { return false }
            let r = rows[row]
            guard r.isExpandable, case .directory(let node) = r.kind else { return false }
            let leading = CGFloat(r.depth) * 14 + 8
            guard pointX >= leading && pointX <= leading + 12 else { return false }
            controller.toggleExpanded(node)
            return true
        }

        // MARK: Context menu

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0, row < rows.count else { return nil }
            let item = rows[row]
            guard let path = itemPath(item) else { return nil }
            let menu = NSMenu()

            if controller.isHostScan {
                menu.addItem(action("Quick Look", { [weak self] in self?.quickLook(URL(fileURLWithPath: path)) }))
                menu.addItem(action("Open", { [weak self] in self?.controller.openItem(path) }))
                menu.addItem(action("Reveal in Finder", { [weak self] in self?.controller.revealInFinder(path) }))
                menu.addItem(action("Copy Path", { [weak self] in self?.controller.copyPath(path) }))
                menu.addItem(.separator())
                let trash = action("Move to Trash", { [weak self] in self?.trashRow(item) })
                trash.isEnabled = !controller.isScanning
                menu.addItem(trash)
                let del = action("Delete Permanently…", { [weak self] in self?.requestDelete(item) })
                del.isEnabled = !controller.isScanning
                menu.addItem(del)
            } else {
                menu.addItem(action("Copy Path (in VM)", { [weak self] in self?.controller.copyPath(path) }))
            }
            return menu
        }

        private func trashRow(_ row: ScanController.OutlineRow) {
            Task { @MainActor in
                let ok: Bool
                switch row.kind {
                case .directory(let node): ok = await controller.remove(directory: node, permanently: false)
                case .file(let f, let parent): ok = await controller.remove(file: f, parent: parent, permanently: false)
                }
                if !ok { reportError("“\(Self.displayName(row))” couldn't be moved to the Trash. It may be on a read-only or network volume.") }
            }
        }

        private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuActionBox.fire), keyEquivalent: "")
            let box = MenuActionBox(handler)
            item.target = box
            item.representedObject = box // retain the box for the menu item's lifetime
            return item
        }

        // MARK: Helpers

        private func select(index: Int) {
            guard let table, index >= 0, index < rows.count else { return }
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            // selectionDidChange pushes to the controller (not suppressed here).
        }

        func primaryIndex() -> Int? {
            if let id = controller.selectedRowID, let idx = rowIDs.firstIndex(of: id) { return idx }
            if let table, table.selectedRow >= 0, table.selectedRow < rows.count { return table.selectedRow }
            return nil
        }

        func primaryRow() -> ScanController.OutlineRow? { primaryIndex().map { rows[$0] } }

        func selectedRows() -> [ScanController.OutlineRow] {
            guard let table else { return [] }
            return table.selectedRowIndexes.filter { $0 >= 0 && $0 < rows.count }.map { rows[$0] }
        }

        private func itemPath(_ row: ScanController.OutlineRow) -> String? {
            switch row.kind {
            case .directory(let node): return controller.path(for: node)
            case .file(let file, let parent): return controller.path(forFile: file, parent: parent)
            }
        }

        static func displayName(_ row: ScanController.OutlineRow) -> String {
            switch row.kind {
            case .directory(let node): return node.name
            case .file(let file, _): return file.name
            }
        }
    }
}

/// Boxes a closure so it can be an `NSMenuItem` target (retained via
/// `representedObject`).
private final class MenuActionBox: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// One outline row: hosts the SwiftUI `OutlineRowView`. Non-interactive so the
/// table owns every mouse event (deterministic selection); the chevron and
/// context menu are handled by the table via geometry / `menu(for:)`.
final class DirectoryRowCell: NSTableCellView {
    private var hosting: NSHostingView<OutlineRowView>?

    func configure(_ view: OutlineRowView) {
        if let hosting {
            hosting.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: leadingAnchor),
                h.trailingAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: topAnchor),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting = h
        }
    }

    // The table (not the hosted SwiftUI) owns all clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `NSTableView` subclass routing keyboard + mouse to the coordinator.
final class MacDirTableView: NSTableView {
    weak var coord: DirectoryTable.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    /// Route every in-bounds click straight to the table (not the hosted SwiftUI
    /// cells, which are purely visual). This is what makes selection deterministic
    /// — `NSTableView.mouseDown` selects via `row(at:)`, independent of the cells —
    /// instead of depending on responder-chain forwarding through the row views.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : super.hitTest(point)
    }

    override func keyDown(with event: NSEvent) {
        guard let coord else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case 51, 117: // delete / forward-delete
            if flags.contains(.command) { coord.trashSelection(); return }
        case 49: // space → Quick Look
            coord.quickLookSelection(); return
        case 36, 76: // return / enter → activate
            coord.activatePrimary(); return
        case 123: // ←
            if coord.handleLeftArrow() { return }
        case 124: // →
            if coord.handleRightArrow() { return }
        default: break
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let clicked = row(at: p)
        if clicked >= 0, let coord, coord.handleChevronClick(row: clicked, pointX: p.x) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let clicked = row(at: p)
        guard clicked >= 0, let coord else { return nil }
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return coord.contextMenu(forRow: clicked)
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        coord?.setHovered(row(at: p))
    }

    override func mouseExited(with event: NSEvent) { coord?.setHovered(-1) }
}
