import SwiftUI
import QuickLook

/// Live directory outline: folders plus the files inside each opened folder
/// (listed on demand). Rendered by a native `NSTableView` (`DirectoryTable`) for
/// deterministic keyboard navigation, multi-selection and focus; this wrapper
/// owns the SwiftUI-level chrome (delete confirmation, error alert, Quick Look).
struct DirectoryListView: View {
    let controller: ScanController
    @Environment(\.theme) private var theme

    @State private var pendingDelete: ScanController.OutlineRow?
    @State private var deleteError: String?
    @State private var quickLookURL: URL?

    var body: some View {
        // Reading these keeps the representable in sync: `version` at refresh rate,
        // and the selection / reveal / structure inputs on demand.
        let _ = controller.version
        let _ = controller.selectedRowIDs
        let _ = controller.revealTarget
        let _ = controller.expanded
        let rows = controller.visibleRows()

        DirectoryTable(
            controller: controller,
            rows: rows,
            theme: theme,
            version: controller.version,
            requestDelete: { pendingDelete = $0 },
            reportError: { deleteError = $0 },
            quickLook: { quickLookURL = $0 }
        )
        .background(theme.panelBackground)
        .quickLookPreview($quickLookURL)
        .alert("Delete permanently?", isPresented: deleteAlert, presenting: pendingDelete) { row in
            Button("Delete", role: .destructive) { performDelete(row) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { row in
            Text("“\(name(of: row))” will be deleted immediately. This can't be undone.")
        }
        .alert("Couldn't delete", isPresented: errorAlert, presenting: deleteError) { _ in
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    private var errorAlert: Binding<Bool> {
        Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
    }

    private var deleteAlert: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func performDelete(_ row: ScanController.OutlineRow) {
        let label = name(of: row)
        pendingDelete = nil
        Task {
            let ok: Bool
            switch row.kind {
            case .directory(let node): ok = await controller.remove(directory: node, permanently: true)
            case .file(let file, let parent): ok = await controller.remove(file: file, parent: parent, permanently: true)
            }
            if !ok { deleteError = "“\(label)” couldn't be deleted. It may be locked, protected, or already gone." }
        }
    }

    private func name(of row: ScanController.OutlineRow) -> String {
        switch row.kind {
        case .directory(let node): return node.name
        case .file(let file, _): return file.name
        }
    }
}

/// Presentation-only row. All interaction (selection, activation, chevron,
/// context menu, keyboard) is owned by `DirectoryTable`/`MacDirTableView`, so
/// this view carries no gestures — it just draws, keyed off the passed-in state.
struct OutlineRowView: View {
    let row: ScanController.OutlineRow
    let isSelected: Bool
    let isHovered: Bool
    let isDirty: Bool
    let controller: ScanController
    let theme: Theme

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
        case .directory(let node): return node.sizeOnDisk
        case .file(let file, _): return file.physical
        }
    }

    /// Notable apparent-vs-on-disk gap (sparse image, compressed content) —
    /// shown as a dashed badge; the tooltip carries both figures and the cause.
    private var divergence: SizeDivergence? {
        switch row.kind {
        case .directory(let node): return node.divergence
        case .file(let file, _): return file.divergence
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

            if isDirty {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 5, height: 5)
                    .help("Changed on disk — Refresh to re-scan")
            }

            Spacer(minLength: 8)

            if let d = divergence {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .help(d.summary)
                    .accessibilityLabel("Apparent size \(Format.bytes(d.apparent)), \(d.label)")
            }

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
                .help(divergence?.summary ?? "")
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(controller.isDeleting(row.id) ? 0.4 : 1)
        .background(rowBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isDirectory ? "Folder" : "File") \(displayName), \(Format.bytes(size))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowBackground: Color {
        if isSelected { return theme.rowSelected }
        if isHovered { return theme.rowHover }
        return .clear
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
