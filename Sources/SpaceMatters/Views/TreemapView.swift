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

    // Memoisation for `recompute`, persisted across relayouts. Held by reference so
    // mutating it never invalidates the view — it's pure side storage, not an input.
    @State private var cache = RenderCache()

    /// Brightness quantisation for the colour LUT: one step is below a single
    /// 8-bit channel, so bucketing is imperceptible while bounding the LUT size.
    private static let brightnessBuckets = 256

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
                    // Double-click: open a file tile, dive into a folder tile, or
                    // pop back out on a leaf/gap — a mouse-only way to zoom.
                    if let hovered {
                        if let file = hovered.file {
                            if let base = controller.path(for: hovered.node) {
                                controller.openItem((base == "/" ? "/" : base + "/") + file.name)
                            }
                        } else if hovered.node.isDirectory {
                            controller.zoom(into: hovered.node)
                        } else {
                            controller.zoomOut()
                        }
                    } else {
                        controller.zoomOut()
                    }
                }
            )
            .contextMenu {
                if let hovered { treemapMenu(for: hovered) }
            }
            .overlay(alignment: .bottomLeading) {
                if let hovered {
                    if let file = hovered.file {
                        HoverLabel(title: file.name, isDirectory: false, sizeText: Format.bytes(file.size))
                            .padding(8).allowsHitTesting(false)
                    } else {
                        HoverLabel(title: hoverPath(hovered.node), isDirectory: hovered.node.isDirectory,
                                   sizeText: Format.bytes(hovered.node.size(controller.metric)))
                            .padding(8).allowsHitTesting(false)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap")
            .accessibilityValue(treemapSummary)
            .onAppear { recompute(size: geo.size) }
            .onChange(of: geo.size) { _, size in recompute(size: size) }
            .onChange(of: controller.version) { _, _ in recompute(size: lastSize) }
            .onChange(of: controller.zoomRoot) { _, _ in recompute(size: lastSize) }
            .onChange(of: controller.metric) { _, _ in recompute(size: lastSize) }
            .onChange(of: theme.isDark) { _, _ in recompute(size: lastSize) }
        }
    }

    private func recompute(size: CGSize) {
        hovered = nil // old tile no longer exists after a relayout — avoid a ghost outline
        guard let zoom = controller.zoomRoot, size.width > 1, size.height > 1 else {
            tiles = []; colors = []; regions = [:]; generation &+= 1
            return
        }
        lastSize = size
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)

        // SPEC-05 (B2): refine the zoom root's own files into individual tiles.
        // The overview (root of the scan, or any level "from afar") stays folder-
        // granular; only the folder you've entered shows its files.
        let rootFiles = rootFileTiles(for: zoom)

        let result = TreemapLayout.compute(root: zoom, rect: rect, metric: controller.metric, rootFiles: rootFiles)
        let newTiles = result.tiles

        var maxSize: Int64 = 1
        for tile in newTiles {
            let s = tileSize(tile)
            if s > maxSize { maxSize = s }
        }
        let denom = Double(maxSize)

        // Colour by file type (matches the legend); size → brightness. Both inputs
        // are size-independent, so a resize never changes a tile's colour — only the
        // tile set/order. Memoise so the loop takes no lock and, once warm, allocates
        // no String/Color: hue indices are cached per node, and finished colours are
        // reused from a bounded LUT. Invalidate only when the theme or tree changes.
        let paletteCount = Theme.paletteHues.count
        let colorKey = ColorCacheKey(isDark: theme.isDark, version: controller.version)
        if cache.colorKey != colorKey {
            cache.hueIndex.removeAll(keepingCapacity: true)
            cache.colorLUT = Array(repeating: nil, count: paletteCount * Self.brightnessBuckets)
            cache.colorKey = colorKey
        }

        var newColors = [Color]()
        newColors.reserveCapacity(newTiles.count)
        for tile in newTiles {
            let weight = min(1.0, max(0.0, pow(Double(tileSize(tile)) / denom, 0.40)))
            // File tiles carry their own extension (a plain field); directory tiles
            // read the dominant one under a lock + string-decode, so cache that index.
            let hueIdx: Int
            if let ext = tile.file?.extName {
                hueIdx = Theme.stableIndex(ext, paletteCount)
            } else {
                let oid = ObjectIdentifier(tile.node)
                if let cached = cache.hueIndex[oid] {
                    hueIdx = cached
                } else {
                    hueIdx = Theme.stableIndex(tile.node.dominantExt.displayName, paletteCount)
                    cache.hueIndex[oid] = hueIdx
                }
            }
            let bucket = min(Self.brightnessBuckets - 1, Int(weight * Double(Self.brightnessBuckets)))
            let lutKey = hueIdx * Self.brightnessBuckets + bucket
            if let cached = cache.colorLUT[lutKey] {
                newColors.append(cached)
            } else {
                // Colour from the bucket centre so the LUT is a pure function of its
                // key, independent of which tile happened to fill the slot first.
                let color = theme.treemapTypeColor(
                    hueIndex: hueIdx, weight: (Double(bucket) + 0.5) / Double(Self.brightnessBuckets))
                cache.colorLUT[lutKey] = color
                newColors.append(color)
            }
        }

        tiles = newTiles
        colors = newColors
        regions = result.regions
        generation &+= 1
    }

    private func tileSize(_ tile: TreemapTile) -> Int64 {
        if let file = tile.file { return file.size }
        return tile.isFileBlock ? tile.node.directFilesSize(controller.metric) : tile.node.size(controller.metric)
    }

    /// The zoom root's own files as tiles (SPEC-05), memoised. The mapping depends
    /// only on `(zoom, metric, tree version)` — never on the treemap's *size* — so a
    /// resize, which reruns the layout every frame, reuses the cached array instead
    /// of re-mapping up to `maxFilesPerFolder` files (each deriving an extension
    /// label — a `String` allocation) every frame.
    private func rootFileTiles(for zoom: FSNode) -> [FileTileInfo]? {
        // Only post-scan: during a scan the count churns and would re-enumerate the
        // folder's files every refresh. Files refine once the scan settles.
        guard controller.isHostScan, !controller.isScanning else { return nil }
        let key = RootFilesKey(zoom: ObjectIdentifier(zoom), metric: controller.metric, version: controller.version)
        if cache.rootFilesKey == key { return cache.rootFiles }
        let items = controller.filesIn(zoom)
        let tiles: [FileTileInfo]? = items.isEmpty ? nil : items.map {
            FileTileInfo(name: $0.name, size: $0.size(controller.metric),
                         extName: OutlineRowView.extDisplay($0.name))
        }
        cache.rootFiles = tiles
        cache.rootFilesKey = key
        return tiles
    }

    /// A spoken summary of the (Canvas-opaque) treemap: the zoomed folder plus its
    /// largest children by share — so VoiceOver conveys the shape of the map.
    private var treemapSummary: String {
        guard let zoom = controller.zoomRoot else { return "" }
        let m = controller.metric
        let head = "Showing \(zoom.name), \(Format.bytes(zoom.size(m)))."
        let total = max(zoom.size(m), 1)
        let kids = controller.sortedChildren(zoom).prefix(5).map {
            "\($0.name) \(Int((Double($0.size(m)) / Double(total) * 100).rounded())) percent"
        }
        return kids.isEmpty ? head : head + " Largest: " + kids.joined(separator: ", ")
    }

    private func hitTest(_ point: CGPoint) -> TreemapTile? {
        for tile in tiles.reversed() where tile.rect.contains(point) { return tile }
        return nil
    }

    /// Path of a tile relative to the current zoom root — so identical folder
    /// names (`Caches`, `node_modules`) are distinguishable on hover.
    private func hoverPath(_ node: FSNode) -> String {
        guard let zoom = controller.zoomRoot, node !== zoom else { return node.name }
        var parts: [String] = []
        var cur: FSNode? = node
        while let n = cur, n !== zoom { parts.append(n.name); cur = n.parent }
        return parts.reversed().joined(separator: "/")
    }

    @ViewBuilder
    private func treemapMenu(for tile: TreemapTile) -> some View {
        if let file = tile.file, let base = controller.path(for: tile.node) {
            // A single file of the zoom root (SPEC-05).
            let path = (base == "/" ? "/" : base + "/") + file.name
            Button { controller.openItem(path) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { controller.revealInFinder(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { controller.copyPath(path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        } else {
            treemapDirMenu(for: tile.node)
        }
    }

    @ViewBuilder
    private func treemapDirMenu(for node: FSNode) -> some View {
        if node.isDirectory {
            Button { controller.zoom(into: node) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
        }
        if controller.canZoomOut {
            Button { controller.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
        }
        if let path = controller.path(for: node) {
            Divider()
            if controller.isHostScan {
                Button { controller.revealInFinder(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { controller.copyPath(path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                Divider()
                Button { Task { _ = await controller.remove(directory: node, permanently: false) } } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(controller.isScanning)
            } else {
                Button { controller.copyPath(path) } label: { Label("Copy Path (in VM)", systemImage: "doc.on.doc") }
            }
        }
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

/// Identifies the inputs that determine the zoom root's file tiles. When it's
/// unchanged (e.g. across a resize), the mapped `FileTileInfo` array is reused.
private struct RootFilesKey: Equatable {
    let zoom: ObjectIdentifier
    let metric: SizeMetric
    let version: UInt64
}

/// Identifies the inputs that determine tile colours. A tile's colour is a pure
/// function of its hue (dominant/own extension) and brightness (relative size) —
/// neither depends on the treemap's size — plus the theme. `(isDark, version)`
/// captures every way the extensions or theme can change, so while it holds the
/// colour memo below stays valid across resizes.
private struct ColorCacheKey: Equatable {
    let isDark: Bool
    let version: UInt64
}

/// Per-view render memo, persisted across relayouts (see `TreemapView.cache`).
/// A reference type so mutating it is invisible to SwiftUI — it caches results
/// whose inputs don't change on resize, keeping the resize path allocation-free.
private final class RenderCache {
    var rootFiles: [FileTileInfo]?
    var rootFilesKey: RootFilesKey?

    /// Directory tiles colour by their dominant extension, read under a lock and
    /// decoded to a `String`. That's stable per node, so memoise the resolved
    /// palette index to spare the lock + allocation on every resize frame.
    var hueIndex: [ObjectIdentifier: Int] = [:]

    /// Colours reused across tiles and frames, keyed by `hueIndex * brightnessBuckets
    /// + bucket`. Bounded to `paletteCount * brightnessBuckets` entries, so once warm
    /// the colour loop constructs no `Color` at all. Brightness is quantised to
    /// `brightnessBuckets` levels — a step below one 8-bit channel, imperceptible.
    var colorLUT: [Color?] = []
    var colorKey: ColorCacheKey?
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
                    // File tiles match on their own extension; folder tiles on their dominant one.
                    let tileExt = tile.file?.extName ?? tile.node.dominantExt.displayName
                    dimmed = tileExt != ext.displayName
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

                // Label big directory + file tiles (not the aggregate block).
                let label = tile.file?.name ?? (tile.isFileBlock ? nil : tile.node.name)
                if !dimmed, let label, r.width > 64, r.height > 22 {
                    let labelRect = r.insetBy(dx: 5, dy: 3)
                    var text = ctx.resolve(Text(label)
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
