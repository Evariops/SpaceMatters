import SwiftUI
import AppKit

// Chrome shared by the two GPU map views — treemap (SPEC-10) and sunburst
// (SPEC-13): hover pill, Metal-unavailable state, context-menu building and
// the spoken summary. Both views observe the *same* `ScanController` and walk
// the same `FSNode` tree — the two modes are two projections of one scan, so
// switching between them never re-scans and keeps zoom/selection/search.

/// The map pane's projection. Both modes render the same scan through the same
/// controller — switching is instant, no re-scan, navigation state carries over.
enum MapMode: String, CaseIterable {
    case treemap
    case sunburst
}

/// The hover pill's payload — computed in the NSViews, rendered by SwiftUI.
struct HoverInfo: Equatable {
    let title: String
    let isDirectory: Bool
    let sizeText: String
}

/// Isolates the hover state so a mouse move only re-evaluates the pill
/// overlay — not the host view's whole body (which would re-diff the
/// representable's inputs and recompute the a11y summary per event).
@MainActor @Observable
final class HoverModel {
    var info: HoverInfo?
}

/// The only view that observes `HoverModel.info` — mouse moves invalidate it alone.
struct HoverPill: View {
    let model: HoverModel
    var body: some View {
        if let hover = model.info {
            HoverLabel(title: hover.title, isDirectory: hover.isDirectory, sizeText: hover.sizeText)
                .padding(8).allowsHitTesting(false)
        }
    }
}

private struct HoverLabel: View {
    let title: String
    let isDirectory: Bool
    let sizeText: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(theme.accent)
            Text(title)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            Text(sizeText)
                .foregroundStyle(theme.textSecondary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.panelBackground.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.separator))
        )
    }
}

/// Shown when a Metal renderer can't initialise — no GPU device (a VM without
/// paravirtualisation) or a broken runtime shader compile. Every Mac that runs
/// macOS 15 has a Metal GPU, so this is an error state, not a supported mode.
struct MapUnavailableView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(theme.textSecondary)
            Text("GPU rendering unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("SpaceMatters draws its maps with Metal, which this machine doesn't provide.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A spoken summary of a (drawing-opaque) map: the zoomed folder plus its
/// largest children by share — so VoiceOver conveys the shape of either view.
@MainActor
func mapAccessibilitySummary(_ controller: ScanController) -> String {
    guard let zoom = controller.zoomRoot else { return "" }
    let head = "Showing \(zoom.name), \(Format.bytes(zoom.sizeOnDisk))."
    let total = max(zoom.sizeOnDisk, 1)
    let kids = controller.sortedChildren(zoom).prefix(5).map {
        "\($0.name) \(Int((Double($0.sizeOnDisk) / Double(total) * 100).rounded())) percent"
    }
    return kids.isEmpty ? head : head + " Largest: " + kids.joined(separator: ", ")
}

/// Context-menu building shared by both maps — same items, same wording,
/// whatever the projection.
@MainActor
enum MapContextMenu {
    /// Items for a file tile/arc (`node` is the owning directory).
    static func addFileItems(_ menu: NSMenu, fileName: String, node: FSNode, controller: ScanController) {
        guard let base = controller.path(for: node) else { return }
        let path = (base == "/" ? "/" : base + "/") + fileName
        menu.addItem(ClosureMenuItem(title: "Open", symbol: "arrow.up.forward.app") { controller.openItem(path) })
        menu.addItem(ClosureMenuItem(title: "Reveal in Finder", symbol: "folder") { controller.revealInFinder(path) })
        menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.doc") { controller.copyPath(path) })
    }

    /// Items for a directory (or its own-files block) tile/arc.
    static func addDirectoryItems(_ menu: NSMenu, node: FSNode, controller: ScanController) {
        if node.isDirectory {
            menu.addItem(ClosureMenuItem(title: "Zoom In", symbol: "plus.magnifyingglass") { controller.zoom(into: node) })
        }
        if controller.canZoomOut {
            menu.addItem(ClosureMenuItem(title: "Zoom Out", symbol: "minus.magnifyingglass") { controller.zoomOut() })
        }
        guard let path = controller.path(for: node) else { return }
        menu.addItem(.separator())
        if controller.isHostScan {
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder", symbol: "folder") { controller.revealInFinder(path) })
            menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.doc") { controller.copyPath(path) })
            menu.addItem(.separator())
            let trash = ClosureMenuItem(title: "Move to Trash", symbol: "trash") {
                Task { _ = await controller.remove(directory: node, permanently: false) }
            }
            trash.isEnabled = !controller.isScanning
            menu.addItem(trash)
        } else {
            menu.addItem(ClosureMenuItem(title: "Copy Path (in VM)", symbol: "doc.on.doc") { controller.copyPath(path) })
        }
    }
}

/// An `NSMenuItem` that runs a closure when chosen.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func fire() { handler() }
}
