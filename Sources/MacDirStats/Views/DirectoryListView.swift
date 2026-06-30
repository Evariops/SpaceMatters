import SwiftUI

/// Live directory outline: folders plus the files inside each opened folder
/// (listed on demand). Flattened to a single array so the native `List`
/// virtualizes it — selection/expansion stays O(visible-on-screen).
struct DirectoryListView: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    @State private var rows: [ScanController.OutlineRow] = []
    @State private var pendingDelete: ScanController.OutlineRow?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(rows) { row in
                    OutlineRowView(
                        row: row,
                        isSelected: controller.selectedRowID == row.id,
                        metric: controller.metric,
                        controller: controller,
                        requestDelete: { pendingDelete = row }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .id(row.id)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(theme.panelBackground)
            .onAppear { rebuild() }
            .onChange(of: controller.version) { _, _ in rebuild() }
            .onChange(of: controller.expanded) { _, _ in rebuild() }
            .onChange(of: controller.metric) { _, _ in rebuild() }
            .onChange(of: controller.revealTarget) { _, target in
                guard let target else { return }
                // Rebuild first so the target row exists, then scroll to it. Avoids
                // a race where scrollTo runs before the expanded rows are present.
                rebuild()
                DispatchQueue.main.async {
                    proxy.scrollTo(ScanController.RowID.dir(ObjectIdentifier(target)), anchor: .center)
                    controller.revealTarget = nil
                }
            }
            .alert("Delete permanently?", isPresented: deleteAlert, presenting: pendingDelete) { row in
                Button("Delete", role: .destructive) { performDelete(row) }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { row in
                Text("“\(name(of: row))” will be deleted immediately. This can't be undone.")
            }
        }
    }

    private var deleteAlert: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func performDelete(_ row: ScanController.OutlineRow) {
        switch row.kind {
        case .directory(let node): controller.remove(directory: node, permanently: true)
        case .file(let file, let parent): controller.remove(file: file, parent: parent, permanently: true)
        }
        pendingDelete = nil
    }

    private func name(of row: ScanController.OutlineRow) -> String {
        switch row.kind {
        case .directory(let node): return node.name
        case .file(let file, _): return file.name
        }
    }

    private func rebuild() { rows = controller.visibleRows() }
}

private struct OutlineRowView: View {
    let row: ScanController.OutlineRow
    let isSelected: Bool
    let metric: SizeMetric
    let controller: ScanController
    let requestDelete: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    private var isDirectory: Bool {
        if case .directory = row.kind { return true }
        return false
    }

    private var displayName: String {
        switch row.kind {
        case .directory(let node): return node.name
        case .file(let file, _): return file.name
        }
    }

    private var size: Int64 {
        switch row.kind {
        case .directory(let node): return node.size(metric)
        case .file(let file, _): return file.size(metric)
        }
    }

    private var colorKey: String {
        switch row.kind {
        case .directory(let node): return node.dominantExt.displayName
        case .file(let file, _): return Self.extDisplay(file.name)
        }
    }

    private var fraction: Double {
        row.siblingMax > 0 ? min(1, Double(size) / Double(row.siblingMax)) : 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if row.isExpandable {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .foregroundStyle(theme.textSecondary)
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle() }
                } else {
                    Color.clear.frame(width: 12)
                }
            }

            Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(isDirectory ? theme.accent : theme.color(forHashable: colorKey))
                .font(.system(size: 11))
                .frame(width: 14)

            Text(displayName)
                .font(.system(size: 12))
                .foregroundStyle(isDirectory ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.barTrack)
                    Capsule()
                        .fill(theme.color(forHashable: colorKey))
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(width: 70, height: 5)

            Text(Format.bytes(size))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate() })
        .onHover { hovering = $0 }
        .contextMenu { contextMenu() }
    }

    private var rowBackground: Color {
        if isSelected { return theme.rowSelected }
        if hovering { return theme.rowHover }
        return .clear
    }

    @ViewBuilder
    private func contextMenu() -> some View {
        if let path = itemPath() {
            if controller.isHostScan {
                Button { controller.openItem(path) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                Button { controller.revealInFinder(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { controller.copyPath(path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                Divider()
                Button { moveToTrash() } label: { Label("Move to Trash", systemImage: "trash") }
                Button(role: .destructive, action: requestDelete) {
                    Label("Delete Permanently…", systemImage: "trash.slash")
                }
            } else {
                // VM scan: paths live inside the VM, so host actions don't apply.
                Button { controller.copyPath(path) } label: { Label("Copy Path (in VM)", systemImage: "doc.on.doc") }
            }
        }
    }

    private func toggle() {
        if case .directory(let node) = row.kind { controller.toggleExpanded(node) }
    }

    private func select() {
        switch row.kind {
        case .directory(let node): controller.selectDirectory(node)
        case .file(let file, let parent): controller.selectFile(file, parent: parent)
        }
    }

    private func activate() {
        switch row.kind {
        case .directory(let node):
            controller.zoom(into: node)
        case .file(let file, let parent):
            if let path = controller.path(forFile: file, parent: parent) { controller.openItem(path) }
        }
    }

    private func moveToTrash() {
        switch row.kind {
        case .directory(let node): controller.remove(directory: node, permanently: false)
        case .file(let file, let parent): controller.remove(file: file, parent: parent, permanently: false)
        }
    }

    private func itemPath() -> String? {
        switch row.kind {
        case .directory(let node): return controller.path(for: node)
        case .file(let file, let parent): return controller.path(forFile: file, parent: parent)
        }
    }

    /// Extension label matching the File-types legend (e.g. ".png", "[no extension]").
    static func extDisplay(_ name: String) -> String {
        if let dot = name.lastIndex(of: "."),
           dot != name.startIndex,
           dot != name.index(before: name.endIndex) {
            return "." + name[name.index(after: dot)...].lowercased()
        }
        return "[no extension]"
    }
}
