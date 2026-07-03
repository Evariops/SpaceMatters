import SwiftUI

struct TreemapView: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme

    // Cached layout. Recomputed only when an input that affects geometry changes
    // (size, zoom, metric, or live sizes during a scan) — NOT on hover/selection,
    // so highlighting stays instant.
    @State private var tiles: [TreemapTile] = []
    @State private var colors: [Color] = []
    @State private var regions: [ObjectIdentifier: CGRect] = [:]
    @State private var generation: Int = 0
    @State private var lastSize: CGSize = .zero
    @State private var hovered: TreemapTile?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                theme.treemapBackground

                TreemapCanvas(
                    tiles: tiles,
                    colors: colors,
                    border: theme.treemapBorder,
                    generation: generation,
                    isDark: theme.isDark,
                    highlightExt: controller.selectedExt,
                    searchMatchIDs: controller.searchMatchIDs,
                    highlightVersion: controller.highlightVersion
                )
                .equatable()

                if let hovered {
                    let r = hovered.rect
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }

                if let selection = controller.selection, let r = selectionRect(for: selection) {
                    // Spotlight: dim everything outside the selected region.
                    Canvas { ctx, size in
                        var p = Path(CGRect(origin: .zero, size: size))
                        p.addRect(r)
                        ctx.fill(p, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                    }
                    .allowsHitTesting(false)

                    // Dark inner liseré + bright white edge → reads on any tile color.
                    Rectangle()
                        .strokeBorder(Color.black.opacity(0.85), lineWidth: 4)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                        .shadow(color: theme.accent.opacity(0.9), radius: 6)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = hitTest(point)
                case .ended: hovered = nil
                }
            }
            .onTapGesture { point in
                if let tile = hitTest(point) { controller.reveal(tile.node) }
            }
            // simultaneousGesture (not .gesture) so the single tap above fires
            // immediately instead of waiting out the double-click interval.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if let hovered, hovered.node.isDirectory { controller.zoom(into: hovered.node) }
                }
            )
            .overlay(alignment: .bottomLeading) {
                if let hovered {
                    HoverLabel(node: hovered.node, metric: controller.metric)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { recompute(size: geo.size) }
            .onChange(of: geo.size) { _, size in recompute(size: size) }
            .onChange(of: controller.version) { _, _ in recompute(size: lastSize) }
            .onChange(of: controller.zoomRoot) { _, _ in recompute(size: lastSize) }
            .onChange(of: controller.metric) { _, _ in recompute(size: lastSize) }
            .onChange(of: theme.isDark) { _, _ in recompute(size: lastSize) }
        }
    }

    private func recompute(size: CGSize) {
        guard let zoom = controller.zoomRoot, size.width > 1, size.height > 1 else {
            tiles = []; colors = []; regions = [:]; generation &+= 1
            return
        }
        lastSize = size
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let result = TreemapLayout.compute(root: zoom, rect: rect, metric: controller.metric)
        let newTiles = result.tiles

        var maxSize: Int64 = 1
        for tile in newTiles {
            let s = tileSize(tile)
            if s > maxSize { maxSize = s }
        }
        let denom = Double(maxSize)

        var newColors = [Color]()
        newColors.reserveCapacity(newTiles.count)
        for tile in newTiles {
            // Colour by dominant file type (matches the legend); size → brightness.
            let weight = pow(Double(tileSize(tile)) / denom, 0.40)
            newColors.append(theme.treemapTypeColor(extName: tile.node.dominantExt.displayName, weight: weight))
        }

        tiles = newTiles
        colors = newColors
        regions = result.regions
        generation &+= 1
    }

    private func tileSize(_ tile: TreemapTile) -> Int64 {
        tile.isFileBlock ? tile.node.directFilesSize(controller.metric) : tile.node.size(controller.metric)
    }

    private func hitTest(_ point: CGPoint) -> TreemapTile? {
        for tile in tiles.reversed() where tile.rect.contains(point) { return tile }
        return nil
    }

    /// Bounding region of a directory in the current layout — so selecting it in
    /// the list outlines the matching area. If the node itself wasn't given its
    /// own tile (it lives inside an undivided parent tile), fall back to the
    /// nearest ancestor that has a region: that tile is exactly where it lives.
    private func selectionRect(for node: FSNode) -> CGRect? {
        if node === controller.zoomRoot { return nil } // whole map; no outline needed
        var cur: FSNode? = node
        while let n = cur {
            if let r = regions[ObjectIdentifier(n)] { return r }
            if n === controller.zoomRoot { break }
            cur = n.parent
        }
        return nil
    }
}

/// The drawn treemap. Equatable on the layout `generation` / `isDark` /
/// `highlightVersion` so it only re-renders when something that affects the
/// pixels changed — hover and selection overlays live in the parent.
///
/// Each tile gets a soft "cushion" sheen (a light-top / dark-bottom gradient) for
/// a pseudo-3D look, a name label when it's big enough, and dims when a file-type
/// filter is active and it doesn't match.
private struct TreemapCanvas: View, Equatable {
    let tiles: [TreemapTile]
    let colors: [Color]
    let border: Color
    let generation: Int
    let isDark: Bool
    let highlightExt: ExtKey?
    let searchMatchIDs: Set<ObjectIdentifier>
    let highlightVersion: Int

    static func == (lhs: TreemapCanvas, rhs: TreemapCanvas) -> Bool {
        lhs.generation == rhs.generation && lhs.isDark == rhs.isDark && lhs.highlightVersion == rhs.highlightVersion
    }

    private func isUnderMatch(_ node: FSNode) -> Bool {
        var current: FSNode? = node
        while let n = current {
            if searchMatchIDs.contains(ObjectIdentifier(n)) { return true }
            current = n.parent
        }
        return false
    }

    private static let cushion = Gradient(stops: [
        .init(color: .white.opacity(0.16), location: 0),
        .init(color: .clear, location: 0.45),
        .init(color: .black.opacity(0.20), location: 1),
    ])

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, _ in
            let labelColor = GraphicsContext.Shading.color(.white.opacity(0.92))
            for i in tiles.indices {
                let tile = tiles[i]
                let r = tile.rect
                if r.width <= 0.5 || r.height <= 0.5 { continue }
                let path = Path(r)

                ctx.fill(path, with: .color(colors[i]))

                // Cushion sheen (skip the tiniest tiles for perf/clarity).
                if r.width > 6 && r.height > 6 {
                    ctx.fill(path, with: .linearGradient(Self.cushion,
                                                         startPoint: CGPoint(x: r.midX, y: r.minY),
                                                         endPoint: CGPoint(x: r.midX, y: r.maxY)))
                }

                let dimmed: Bool
                if let ext = highlightExt {
                    dimmed = tile.node.dominantExt != ext
                } else if !searchMatchIDs.isEmpty {
                    dimmed = !isUnderMatch(tile.node)
                } else {
                    dimmed = false
                }
                if dimmed {
                    ctx.fill(path, with: .color(.black.opacity(0.72)))
                }

                if r.width > 3 && r.height > 3 {
                    ctx.stroke(path, with: .color(border), lineWidth: 0.6)
                }

                // Label big directory tiles.
                if !dimmed, !tile.isFileBlock, r.width > 64, r.height > 22 {
                    let labelRect = r.insetBy(dx: 5, dy: 3)
                    var text = ctx.resolve(Text(tile.node.name)
                        .font(.system(size: 10.5, weight: .medium)))
                    text.shading = labelColor
                    ctx.draw(text, in: CGRect(x: labelRect.minX, y: labelRect.minY,
                                              width: labelRect.width, height: 14))
                }
            }
        }
        .drawingGroup()
    }
}

private struct HoverLabel: View {
    let node: FSNode
    let metric: SizeMetric
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(theme.accent)
            Text(node.name)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(Format.bytes(node.size(metric)))
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
