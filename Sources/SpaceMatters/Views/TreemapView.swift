import SwiftUI
import AppKit
import Metal
import QuartzCore

/// Treemap view. The map itself is drawn by a plain AppKit `NSView`
/// (`TreemapNSView`) rather than a SwiftUI `Canvas`, so a window resize is driven
/// straight by AppKit — `setFrameSize` → recompute rects → redraw — with **no**
/// SwiftUI recompute / reconcile / display-list trip per frame. Profiling showed
/// that per-frame SwiftUI machinery, not the drawing, was the resize bottleneck.
///
/// This thin SwiftUI wrapper only: (1) reads the controller's observable inputs so
/// SwiftUI calls `updateNSView` when they change, (2) hosts the hover-label overlay
/// (interaction chrome, not perf-critical), and (3) carries accessibility.
struct TreemapView: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme
    @State private var hover: HoverInfo?

    var body: some View {
        // Reading these establishes SwiftUI observation: when any changes, `body`
        // re-evaluates → the representable is recreated → `updateNSView` runs. A
        // resize is NOT observed here (no GeometryReader) — AppKit drives it.
        TreemapRepresentable(
            controller: controller,
            theme: theme,
            version: controller.version,
            zoomRoot: controller.zoomRoot,
            metric: controller.metric,
            selection: controller.selection,
            selectedExt: controller.selectedExt,
            searchMatchIDs: controller.searchMatchIDs,
            highlightVersion: controller.highlightVersion,
            isDark: theme.isDark,
            onHover: { hover = $0 }
        )
        .overlay(alignment: .bottomLeading) {
            if let hover {
                HoverLabel(title: hover.title, isDirectory: hover.isDirectory, sizeText: hover.sizeText)
                    .padding(8).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Treemap")
        .accessibilityValue(treemapSummary)
    }

    /// A spoken summary of the (drawing-opaque) treemap: the zoomed folder plus its
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
}

/// The hover pill's payload — computed in the NSView, rendered by SwiftUI.
struct HoverInfo: Equatable {
    let title: String
    let isDirectory: Bool
    let sizeText: String
}

/// Bridges the AppKit `TreemapNSView` into SwiftUI. `updateNSView` pushes the
/// current observable inputs; the NSView decides what that implies (relayout vs a
/// cheap overlay/dimming redraw).
private struct TreemapRepresentable: NSViewRepresentable {
    let controller: ScanController
    let theme: Theme
    let version: UInt64
    let zoomRoot: FSNode?
    let metric: SizeMetric
    let selection: FSNode?
    let selectedExt: ExtKey?
    let searchMatchIDs: Set<ObjectIdentifier>
    let highlightVersion: Int
    let isDark: Bool
    let onHover: (HoverInfo?) -> Void

    func makeNSView(context: Context) -> TreemapNSView {
        let view = TreemapNSView()
        view.onHover = onHover
        view.apply(controller: controller, theme: theme, version: version, zoomRoot: zoomRoot,
                   metric: metric, selection: selection, selectedExt: selectedExt,
                   searchMatchIDs: searchMatchIDs, highlightVersion: highlightVersion)
        return view
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.onHover = onHover
        view.apply(controller: controller, theme: theme, version: version, zoomRoot: zoomRoot,
                   metric: metric, selection: selection, selectedExt: selectedExt,
                   searchMatchIDs: searchMatchIDs, highlightVersion: highlightVersion)
    }
}

/// The drawn treemap: an AppKit view AppKit resizes directly. Tiles live in one
/// cached layer (redrawn only on relayout — resize or model change); the hover
/// outline + selection spotlight live in a second layer (redrawn on hover/selection
/// alone), so hovering never re-renders the ~thousands of tiles.
///
/// Allocation discipline (the resize hot path is `setFrameSize` → `relayout` →
/// `draw`): the cushion gradient, tile CGColors (a bounded LUT), theme CGColors and
/// label attributed-strings are all cached and reused across frames; the per-frame
/// `colors`/`sizeScratch` buffers keep their capacity. Only the tiles array (whose
/// rects genuinely change every frame) is rebuilt.
final class TreemapNSView: NSView, CALayerDelegate {
    var onHover: ((HoverInfo?) -> Void)?

    // Inputs (mirrored from SwiftUI via `apply`).
    private var controller: ScanController?
    private var theme = Theme(isDark: true)
    private var version: UInt64 = .max
    private var zoomRoot: FSNode?
    private var metric: SizeMetric = .physical
    private var selection: FSNode?
    private var selectedExt: ExtKey?
    private var searchMatchIDs: Set<ObjectIdentifier> = []
    private var highlightVersion: Int = .min
    private var isDark = true

    // Layout state.
    private var tiles: [TreemapTile] = []
    private var colors: [CGColor] = []            // CG fallback path
    private var instances: [TileInstance] = []    // Metal path (culled to visible tiles)
    private var regions: [ObjectIdentifier: CGRect] = [:]
    private var regionsBuilt = false
    private var hovered: TreemapTile?

    // Tile layer: a `CAMetalLayer` when a GPU is available (the fast path — SPEC-09),
    // else a plain `CALayer` rasterised by CoreGraphics (defensive fallback). The
    // selection/hover overlay stays a CG layer above it (Phase 1).
    private let tileLayer: CALayer
    private let metalLayer: CAMetalLayer?
    private let renderer: TreemapMetalRenderer?
    private let overlayLayer = CALayer()

    // MARK: Caches (persist across relayouts)

    private static let brightnessBuckets = 256
    private let paletteCount = Theme.paletteHues.count
    private var hueIndexCache: [ObjectIdentifier: Int] = [:]
    private var colorLUT: [CGColor?] = []
    private var colorLUTf: [SIMD4<Float>?] = []
    private var colorKey: ColorKey?
    private var sizeScratch: [Int64] = []

    private var rootFilesCache: [FileTileInfo]?
    private var rootFilesKey: RootFilesKey?

    // Theme-derived CGColors (rebuilt on theme change).
    private var backgroundCG = CGColor(gray: 0, alpha: 1)
    private var borderCG = CGColor(gray: 0, alpha: 0.45)
    private var accentShadowCG = CGColor(gray: 0.3, alpha: 0.9)
    // Theme-derived sRGB components for the Metal clear + border uniform.
    private var backgroundComps = SIMD4<Float>(0, 0, 0, 1)
    private var borderComps = SIMD4<Float>(0, 0, 0, 0.45)
    private static let dimCG = CGColor(gray: 0, alpha: 0.72)
    private static let spotlightDimCG = CGColor(gray: 0, alpha: 0.5)
    private static let blackBorderCG = CGColor(gray: 0, alpha: 0.85)
    private static let whiteCG = CGColor(gray: 1, alpha: 1)
    private static let hoverCG = CGColor(gray: 1, alpha: 0.95)

    private lazy var cushionGradient: CGGradient = {
        let space = CGColorSpaceCreateDeviceRGB()
        let stops: [CGColor] = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.20),
        ]
        return CGGradient(colorsSpace: space, colors: stops as CFArray, locations: [0, 0.45, 1])!
    }()

    private struct ColorKey: Equatable { let isDark: Bool; let version: UInt64 }

    // MARK: Setup

    override init(frame frameRect: NSRect) {
        if let renderer = TreemapMetalRenderer() {
            let ml = CAMetalLayer()
            ml.device = renderer.device
            ml.pixelFormat = .bgra8Unorm            // non-sRGB: store sRGB values as-is → matches CG
            ml.framebufferOnly = true
            ml.isOpaque = true
            ml.presentsWithTransaction = true       // atomic present with bounds during live-resize
            ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            self.renderer = renderer
            self.metalLayer = ml
            self.tileLayer = ml
        } else {
            self.renderer = nil
            self.metalLayer = nil
            self.tileLayer = CALayer()
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.masksToBounds = true

        // Metal draws itself (no CALayerDelegate); the CG fallback layer uses `draw`.
        if metalLayer == nil {
            tileLayer.delegate = self
            tileLayer.needsDisplayOnBoundsChange = true
            tileLayer.contentsScale = 2
        }
        tileLayer.frame = bounds
        layer?.addSublayer(tileLayer)

        overlayLayer.delegate = self
        overlayLayer.needsDisplayOnBoundsChange = true
        overlayLayer.contentsScale = 2
        overlayLayer.frame = bounds
        layer?.addSublayer(overlayLayer)

        rebuildThemeColors()   // seed background/border (CG + Metal comps) from the default theme
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !inLiveResize else { return }   // don't fight the live-resize scale-down
        setScale(window?.backingScaleFactor ?? 2)
    }

    private func setScale(_ scale: CGFloat) {
        if let metalLayer {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            presentTiles()
        } else {
            tileLayer.contentsScale = scale
            tileLayer.setNeedsDisplay()
        }
        overlayLayer.contentsScale = scale
        overlayLayer.setNeedsDisplay()
    }

    // Fallback (no-GPU) path only: CPU rasterisation of the big solid tiles at 2× retina
    // is the resize bottleneck, so during a live drag we fill ¼ the pixels (1× backing)
    // and re-render crisp when it ends. Metal renders full-res cheaply — it skips this.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard renderer == nil else { return }
        tileLayer.contentsScale = 1
        overlayLayer.contentsScale = 1
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard renderer == nil else { return }
        setScale(window?.backingScaleFactor ?? 2)
    }

    // MARK: SwiftUI → view

    func apply(controller: ScanController, theme: Theme, version: UInt64, zoomRoot: FSNode?,
               metric: SizeMetric, selection: FSNode?, selectedExt: ExtKey?,
               searchMatchIDs: Set<ObjectIdentifier>, highlightVersion: Int) {
        self.controller = controller

        let themeChanged = isDark != theme.isDark
        self.theme = theme
        self.isDark = theme.isDark
        if themeChanged { rebuildThemeColors() }

        let structural = version != self.version || zoomRoot !== self.zoomRoot
            || metric != self.metric || themeChanged
        let highlightChanged = selectedExt != self.selectedExt
            || highlightVersion != self.highlightVersion || searchMatchIDs != self.searchMatchIDs
        let selectionChanged = selection !== self.selection

        self.version = version
        self.zoomRoot = zoomRoot
        self.metric = metric
        self.selectedExt = selectedExt
        self.searchMatchIDs = searchMatchIDs
        self.highlightVersion = highlightVersion
        self.selection = selection

        if structural {
            relayout()
            presentTiles()
            overlayLayer.setNeedsDisplay()
        } else {
            if selectionChanged && selection != nil && !regionsBuilt {
                relayout()               // need the region map to outline the new selection
                presentTiles()
            } else if highlightChanged {
                computeColors()          // dimming changed; rects unchanged → repack (Metal folds dim in)
                presentTiles()
            }
            if selectionChanged { overlayLayer.setNeedsDisplay() }
        }
    }

    private func rebuildThemeColors() {
        backgroundCG = NSColor(theme.treemapBackground).cgColor
        borderCG = NSColor(theme.treemapBorder).cgColor
        accentShadowCG = NSColor(theme.accent).withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = backgroundCG
        backgroundComps = srgbComps(theme.treemapBackground)
        borderComps = srgbComps(theme.treemapBorder)
    }

    private func srgbComps(_ color: Color) -> SIMD4<Float> {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return SIMD4<Float>(Float(ns.redComponent), Float(ns.greenComponent),
                            Float(ns.blueComponent), Float(ns.alphaComponent))
    }

    // MARK: Resize (AppKit-driven — the hot path)

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        tileLayer.frame = bounds
        overlayLayer.frame = bounds
        if let metalLayer {
            let scale = window?.backingScaleFactor ?? 2
            metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        }
        relayout()
        presentTiles()
        overlayLayer.setNeedsDisplay()
    }

    // MARK: Layout (size-dependent placement + colours)

    private func relayout() {
        hovered = nil
        guard let controller, let zoomRoot, bounds.width > 1, bounds.height > 1 else {
            tiles = []; colors.removeAll(keepingCapacity: true); instances.removeAll(keepingCapacity: true)
            regions = [:]; regionsBuilt = false
            return
        }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let rootFiles = rootFileTiles(for: zoomRoot, controller: controller)
        let needRegions = selection != nil
        let result = controller.treemapLayout(root: zoomRoot, rect: rect, rootFiles: rootFiles,
                                              needsRegions: needRegions)
        tiles = result.tiles
        regions = result.regions
        regionsBuilt = needRegions
        computeColors()
    }

    /// Fill `colors` (parallel to `tiles`) from the LUT. Size is read once per tile
    /// (into `sizeScratch`) and reused for both the max pass and the weight, halving
    /// the atomic loads; `colors` keeps its buffer capacity across frames.
    private func computeColors() {
        let n = tiles.count
        let key = ColorKey(isDark: isDark, version: version)
        if colorKey != key {
            hueIndexCache.removeAll(keepingCapacity: true)
            colorLUT = Array(repeating: nil, count: paletteCount * Self.brightnessBuckets)
            colorLUTf = Array(repeating: nil, count: paletteCount * Self.brightnessBuckets)
            colorKey = key
        }
        if sizeScratch.count < n { sizeScratch = [Int64](repeating: 0, count: n) }
        var maxSize: Int64 = 1
        for i in 0..<n {
            let s = tileSize(tiles[i])
            sizeScratch[i] = s
            if s > maxSize { maxSize = s }
        }
        let denom = Double(maxSize)
        if renderer != nil {
            packInstances(denom: denom)
        } else {
            colors.removeAll(keepingCapacity: true)
            colors.reserveCapacity(n)
            for i in 0..<n {
                let weight = min(1.0, max(0.0, pow(Double(sizeScratch[i]) / denom, 0.40)))
                colors.append(cgColor(for: tiles[i], weight: weight))
            }
        }
    }

    /// Pack `tiles` into GPU `instances` (Metal path): world rect on the ground plane
    /// (top-left, height 0), packed sRGB colour, dim folded in. Sub-pixel tiles are
    /// culled here — `instances` may be shorter than `tiles`; hit-testing uses `tiles`.
    private func packInstances(denom: Double) {
        let n = tiles.count
        instances.removeAll(keepingCapacity: true)
        instances.reserveCapacity(n)
        let highlightName = selectedExt?.displayName
        let hasSearch = highlightName == nil && !searchMatchIDs.isEmpty
        for i in 0..<n {
            let tile = tiles[i]
            let r = tile.rect
            if r.width <= 0.5 || r.height <= 0.5 { continue }
            let weight = min(1.0, max(0.0, pow(Double(sizeScratch[i]) / denom, 0.40)))
            var dim: Float = 0
            if let highlightName {
                let tileExt = tile.file?.extName ?? tile.node.dominantExt.displayName
                if tileExt != highlightName { dim = 1 }
            } else if hasSearch, !isUnderMatch(tile.node) {
                dim = 1
            }
            instances.append(TileInstance(
                origin: SIMD4<Float>(Float(r.minX), 0, Float(r.minY), 0),
                size: SIMD4<Float>(Float(r.width), 0, Float(r.height), dim),
                color: floatColor(for: tile, weight: weight)))
        }
    }

    private func cgColor(for tile: TreemapTile, weight: Double) -> CGColor {
        let hueIdx: Int
        if let ext = tile.file?.extName {
            hueIdx = Theme.stableIndex(ext, paletteCount)
        } else {
            let oid = ObjectIdentifier(tile.node)
            if let cached = hueIndexCache[oid] {
                hueIdx = cached
            } else {
                hueIdx = Theme.stableIndex(tile.node.dominantExt.displayName, paletteCount)
                hueIndexCache[oid] = hueIdx
            }
        }
        let bucket = min(Self.brightnessBuckets - 1, Int(weight * Double(Self.brightnessBuckets)))
        let lutKey = hueIdx * Self.brightnessBuckets + bucket
        if let cached = colorLUT[lutKey] { return cached }
        let color = NSColor(theme.treemapTypeColor(
            hueIndex: hueIdx, weight: (Double(bucket) + 0.5) / Double(Self.brightnessBuckets))).cgColor
        colorLUT[lutKey] = color
        return color
    }

    /// sRGB RGBA for a tile (Metal path), memoised in the same `(hueIndex, bucket)` LUT
    /// shape as `cgColor` — no per-frame `NSColor`/hashing on the resize hot path.
    private func floatColor(for tile: TreemapTile, weight: Double) -> SIMD4<Float> {
        let hueIdx: Int
        if let ext = tile.file?.extName {
            hueIdx = Theme.stableIndex(ext, paletteCount)
        } else {
            let oid = ObjectIdentifier(tile.node)
            if let cached = hueIndexCache[oid] {
                hueIdx = cached
            } else {
                hueIdx = Theme.stableIndex(tile.node.dominantExt.displayName, paletteCount)
                hueIndexCache[oid] = hueIdx
            }
        }
        let bucket = min(Self.brightnessBuckets - 1, Int(weight * Double(Self.brightnessBuckets)))
        let lutKey = hueIdx * Self.brightnessBuckets + bucket
        if let cached = colorLUTf[lutKey] { return cached }
        let ns = NSColor(theme.treemapTypeColor(
            hueIndex: hueIdx, weight: (Double(bucket) + 0.5) / Double(Self.brightnessBuckets)))
        let s = ns.usingColorSpace(.sRGB) ?? ns
        let v = SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), 1)
        colorLUTf[lutKey] = v
        return v
    }

    /// Push the current tiles to screen: a GPU render (Metal) or a layer redraw (CG).
    private func presentTiles() {
        if let renderer, let metalLayer {
            renderer.render(into: metalLayer, instances: instances,
                            camera: Camera.orthoTopDown(width: Float(bounds.width), height: Float(bounds.height)),
                            clearColor: backgroundComps, borderColor: borderComps)
        } else {
            tileLayer.setNeedsDisplay()
        }
    }

    private func tileSize(_ tile: TreemapTile) -> Int64 {
        if let file = tile.file { return file.size }
        return tile.isFileBlock ? tile.node.directFilesSize(metric) : tile.node.size(metric)
    }

    /// The zoom root's own files as tiles (SPEC-05), memoised by (zoom, metric,
    /// version) so a resize reuses the mapping instead of re-deriving extension
    /// labels for up to `maxFilesPerFolder` files every frame.
    private func rootFileTiles(for zoom: FSNode, controller: ScanController) -> [FileTileInfo]? {
        guard controller.isHostScan, !controller.isScanning else { return nil }
        let key = RootFilesKey(zoom: ObjectIdentifier(zoom), metric: metric, version: version)
        if rootFilesKey == key { return rootFilesCache }
        let items = controller.filesIn(zoom)
        let mapped: [FileTileInfo]? = items.isEmpty ? nil : items.map {
            FileTileInfo(name: $0.name, size: $0.size(metric), extName: OutlineRowView.extDisplay($0.name))
        }
        rootFilesCache = mapped
        rootFilesKey = key
        return mapped
    }

    // MARK: Drawing

    func draw(_ layer: CALayer, in ctx: CGContext) {
        // The layer context is native Core Graphics: bottom-left, y-up, text upright.
        // The tile rects are top-left, so each is flipped into this space at draw time
        // (`flip`). No context or text-matrix flips — so glyphs can never mirror.
        if layer === tileLayer {
            drawTiles(in: ctx, height: layer.bounds.height)
        } else if layer === overlayLayer {
            drawOverlay(in: ctx, size: layer.bounds.size)
        }
    }

    /// Flip a top-left tile rect into the context's native bottom-left space.
    private func flip(_ r: CGRect, _ height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private func drawTiles(in ctx: CGContext, height: CGFloat) {
        let n = tiles.count
        guard n > 0, colors.count == n else { return }
        let highlightName = selectedExt?.displayName
        let hasSearch = highlightName == nil && !searchMatchIDs.isEmpty

        for i in 0..<n {
            let tile = tiles[i]
            if tile.rect.width <= 0.5 || tile.rect.height <= 0.5 { continue }
            let r = flip(tile.rect, height)

            ctx.setFillColor(colors[i])
            ctx.fill(r)

            // Cushion sheen (light top → dark bottom); skip the tiniest tiles.
            if r.width > 6 && r.height > 6 {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.drawLinearGradient(cushionGradient,
                                       start: CGPoint(x: r.midX, y: r.maxY),
                                       end: CGPoint(x: r.midX, y: r.minY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                ctx.restoreGState()
            }

            var dimmed = false
            if let highlightName {
                let tileExt = tile.file?.extName ?? tile.node.dominantExt.displayName
                dimmed = tileExt != highlightName
            } else if hasSearch {
                dimmed = !isUnderMatch(tile.node)
            }
            if dimmed {
                ctx.setFillColor(Self.dimCG)
                ctx.fill(r)
            }

            if r.width > 3 && r.height > 3 {
                ctx.setStrokeColor(borderCG)
                ctx.setLineWidth(0.6)
                ctx.stroke(r)
            }
        }
    }

    private func drawOverlay(in ctx: CGContext, size: CGSize) {
        if let selection, let sel = selectionRect(for: selection) {
            let r = flip(sel, size.height)
            // Spotlight: dim everything outside the selected region.
            ctx.setFillColor(Self.spotlightDimCG)
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.addRect(r)
            ctx.fillPath(using: .evenOdd)

            // Dark inner liseré + bright white edge (strokeBorder draws inside the
            // frame, so inset by half the line width to match).
            ctx.setStrokeColor(Self.blackBorderCG)
            ctx.setLineWidth(4)
            ctx.stroke(r.insetBy(dx: 2, dy: 2))

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: accentShadowCG)
            ctx.setStrokeColor(Self.whiteCG)
            ctx.setLineWidth(2)
            ctx.stroke(r.insetBy(dx: 1, dy: 1))
            ctx.restoreGState()
        }
        if let hovered {
            let r = flip(hovered.rect, size.height)
            ctx.setStrokeColor(Self.hoverCG)
            ctx.setLineWidth(1.5)
            ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))
        }
    }

    private func isUnderMatch(_ node: FSNode) -> Bool {
        var current: FSNode? = node
        while let n = current {
            if searchMatchIDs.contains(ObjectIdentifier(n)) { return true }
            current = n.parent
        }
        return false
    }

    /// Bounding region of a directory in the current layout, falling back to the
    /// nearest ancestor that has one (the tile it visually lives inside).
    private func selectionRect(for node: FSNode) -> CGRect? {
        if node === zoomRoot { return nil }
        var cur: FSNode? = node
        while let n = cur {
            if let r = regions[ObjectIdentifier(n)] { return r }
            if n === zoomRoot { break }
            cur = n.parent
        }
        return nil
    }

    // MARK: Hit testing & interaction

    /// The topmost tile at `point` (a mouse location in view coordinates). Mouse
    /// coordinates arrive bottom-left; the tiles are stored top-left (matching the
    /// layout), so flip Y before hit-testing. Named to avoid clashing with
    /// `NSView.hitTest(_:)`.
    private func tileAt(_ point: CGPoint) -> TreemapTile? {
        let p = CGPoint(x: point.x, y: bounds.height - point.y)
        for tile in tiles.reversed() where tile.rect.contains(p) { return tile }
        return nil
    }

    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = tileAt(p)
        if hit?.rect != hovered?.rect {
            hovered = hit
            overlayLayer.setNeedsDisplay()
            onHover?(hit.map(hoverInfo(for:)))
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        overlayLayer.setNeedsDisplay()
        onHover?(nil)
    }

    override func mouseUp(with event: NSEvent) {
        let tile = tileAt(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            // Double-click: open a file tile, dive into a folder tile, or pop back
            // out on a leaf/gap — a mouse-only way to zoom.
            guard let controller else { return }
            if let tile {
                if let file = tile.file {
                    if let base = controller.path(for: tile.node) {
                        controller.openItem((base == "/" ? "/" : base + "/") + file.name)
                    }
                } else if tile.node.isDirectory {
                    controller.zoom(into: tile.node)
                } else {
                    controller.zoomOut()
                }
            } else {
                controller.zoomOut()
            }
        } else if let tile {
            controller?.reveal(tile.node)
        }
    }

    private func hoverInfo(for tile: TreemapTile) -> HoverInfo {
        if let file = tile.file {
            return HoverInfo(title: file.name, isDirectory: false, sizeText: Format.bytes(file.size))
        }
        return HoverInfo(title: hoverPath(tile.node), isDirectory: tile.node.isDirectory,
                         sizeText: Format.bytes(tile.node.size(metric)))
    }

    /// Path of a node relative to the current zoom root — so identical folder names
    /// (`Caches`, `node_modules`) are distinguishable on hover.
    private func hoverPath(_ node: FSNode) -> String {
        guard let zoom = zoomRoot, node !== zoom else { return node.name }
        var parts: [String] = []
        var cur: FSNode? = node
        while let n = cur, n !== zoom { parts.append(n.name); cur = n.parent }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let tile = tileAt(p), let controller else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let file = tile.file, let base = controller.path(for: tile.node) {
            let path = (base == "/" ? "/" : base + "/") + file.name
            menu.addItem(ClosureMenuItem(title: "Open", symbol: "arrow.up.forward.app") { controller.openItem(path) })
            menu.addItem(ClosureMenuItem(title: "Reveal in Finder", symbol: "folder") { controller.revealInFinder(path) })
            menu.addItem(ClosureMenuItem(title: "Copy Path", symbol: "doc.on.doc") { controller.copyPath(path) })
        } else {
            buildDirMenu(menu, node: tile.node, controller: controller)
        }
        return menu.numberOfItems > 0 ? menu : nil
    }

    private func buildDirMenu(_ menu: NSMenu, node: FSNode, controller: ScanController) {
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

/// Identifies the inputs that determine the zoom root's file tiles.
private struct RootFilesKey: Equatable {
    let zoom: ObjectIdentifier
    let metric: SizeMetric
    let version: UInt64
}

/// An `NSMenuItem` that runs a closure when chosen.
private final class ClosureMenuItem: NSMenuItem {
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
