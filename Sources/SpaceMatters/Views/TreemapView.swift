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
    /// Hover lives in its own observable box so a mouse move only re-evaluates
    /// the pill overlay — not this whole body (which would re-diff the
    /// representable's inputs and recompute the a11y summary per event).
    @State private var hoverModel = HoverModel()

    /// The one GPU renderer, built once per process and shared across view
    /// recreations (the shader is compiled at launch — see `TreemapMetalRenderer`).
    /// `nil` means Metal is genuinely unusable here (no device, or the runtime
    /// shader compile failed): the treemap then shows an explicit failure state
    /// instead of silently degrading — a failure that shows beats one that hides.
    private static let sharedRenderer = TreemapMetalRenderer()

    var body: some View {
        if let renderer = Self.sharedRenderer {
            // Reading these establishes SwiftUI observation: when any changes, `body`
            // re-evaluates → the representable is recreated → `updateNSView` runs. A
            // resize is NOT observed here (no GeometryReader) — AppKit drives it.
            TreemapRepresentable(
                renderer: renderer,
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
                onHover: { [hoverModel] in hoverModel.info = $0 }
            )
            .overlay(alignment: .bottomLeading) {
                HoverPill(model: hoverModel)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Treemap")
            .accessibilityValue(treemapSummary)
        } else {
            TreemapUnavailableView()
        }
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

/// Shown when the Metal renderer can't initialise — no GPU device (a VM without
/// paravirtualisation) or a broken runtime shader compile. Every Mac that runs
/// macOS 15 has a Metal GPU, so this is an error state, not a supported mode.
private struct TreemapUnavailableView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(theme.textSecondary)
            Text("GPU rendering unavailable")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("SpaceMatters draws the treemap with Metal, which this machine doesn't provide.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// The hover pill's payload — computed in the NSView, rendered by SwiftUI.
struct HoverInfo: Equatable {
    let title: String
    let isDirectory: Bool
    let sizeText: String
}

/// Isolates the hover state (see `TreemapView.hoverModel`).
@MainActor @Observable
final class HoverModel {
    var info: HoverInfo?
}

/// The only view that observes `HoverModel.info` — mouse moves invalidate it alone.
private struct HoverPill: View {
    let model: HoverModel
    var body: some View {
        if let hover = model.info {
            HoverLabel(title: hover.title, isDirectory: hover.isDirectory, sizeText: hover.sizeText)
                .padding(8).allowsHitTesting(false)
        }
    }
}

/// Bridges the AppKit `TreemapNSView` into SwiftUI. `updateNSView` pushes the
/// current observable inputs; the NSView decides what that implies (relayout vs a
/// cheap overlay/dimming redraw).
private struct TreemapRepresentable: NSViewRepresentable {
    let renderer: TreemapMetalRenderer
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
        let view = TreemapNSView(renderer: renderer)
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

/// The drawn treemap: an AppKit view AppKit resizes directly. Tiles are rendered by
/// the GPU into the view's backing `CAMetalLayer` (SPEC-09); the hover outline +
/// selection spotlight live in a CG overlay layer (redrawn on hover/selection
/// alone), so hovering never re-renders the ~thousands of tiles.
///
/// Allocation discipline (the resize hot path is `setFrameSize` → `relayout` →
/// `presentTiles`): tile colours (a bounded LUT), the hue-index cache and theme
/// CGColors are all reused across frames; the per-frame `instances`/`sizeScratch`
/// buffers keep their capacity. Only the tiles array (whose rects genuinely change
/// every frame) is rebuilt.
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
    private var instances: [TileInstance] = []    // GPU instances (culled to visible tiles)
    private var regions: [ObjectIdentifier: CGRect] = [:]
    private var regionsBuilt = false
    private var hovered: TreemapTile?

    // Tile layer: the view's backing `CAMetalLayer` (SPEC-09). The selection/hover
    // overlay stays a CG layer above it (Phase 1).
    private let metalLayer: CAMetalLayer
    private let renderer: TreemapMetalRenderer
    private let overlayLayer = CALayer()

    // MARK: Caches (persist across relayouts)

    private static let brightnessBuckets = 256
    private let paletteCount = Theme.paletteHues.count
    private var hueIndexCache: [ObjectIdentifier: Int] = [:]
    private var colorLUT: [SIMD4<Float>?] = []
    private var colorKey: ColorKey?
    private var sizeScratch: [Int64] = []

    private var rootFilesCache: [FileTileInfo]?
    private var rootFilesKey: RootFilesKey?

    // Theme-derived CGColors for the overlay (rebuilt on theme change).
    private var backgroundCG = CGColor(gray: 0, alpha: 1)
    private var accentShadowCG = CGColor(gray: 0.3, alpha: 0.9)
    // Theme-derived sRGB components for the Metal clear + border uniform.
    private var backgroundComps = SIMD4<Float>(0, 0, 0, 1)
    private var borderComps = SIMD4<Float>(0, 0, 0, 0.45)
    private static let spotlightDimCG = CGColor(gray: 0, alpha: 0.5)
    private static let blackBorderCG = CGColor(gray: 0, alpha: 0.85)
    private static let whiteCG = CGColor(gray: 1, alpha: 1)
    private static let hoverCG = CGColor(gray: 1, alpha: 0.95)

    private struct ColorKey: Equatable { let isDark: Bool; let version: UInt64 }

    // MARK: Setup

    init(renderer: TreemapMetalRenderer) {
        self.renderer = renderer
        let ml = CAMetalLayer()
        ml.device = renderer.device
        ml.pixelFormat = .bgra8Unorm            // non-sRGB: tile colours are already sRGB-encoded (`tileColor`)
        ml.framebufferOnly = true
        ml.isOpaque = true
        // `presentsWithTransaction` is turned on only while resizing (see
        // viewWillStartLiveResize / setFrameSize): the synchronous commit +
        // waitUntilScheduled it implies must not tax every ordinary frame.
        ml.presentsWithTransaction = false
        ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        self.metalLayer = ml
        super.init(frame: .zero)
        wantsLayer = true
        // The CAMetalLayer is the view's *backing* layer (see makeBackingLayer), so
        // AppKit resizes it in lockstep with the view — no sublayer-frame lag / black
        // bands during a live drag. The overlay is a sublayer above it. AppKit must not
        // try to CG-redraw the metal layer, so its content-redraw policy is `.never`.
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true

        overlayLayer.delegate = self
        overlayLayer.needsDisplayOnBoundsChange = true
        overlayLayer.contentsScale = 2
        overlayLayer.frame = bounds
        layer?.addSublayer(overlayLayer)

        rebuildThemeColors()   // seed background/border (CG + Metal comps) from the default theme
    }

    /// Hand AppKit the `CAMetalLayer` as the backing layer, so it's resized in
    /// lockstep with the view — the fix for resize lag / black bands.
    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !inLiveResize else { return }   // don't fight the live-resize scale-down
        setScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelZoom() }     // break the CADisplayLink → self cycle on teardown
    }

    private func setScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        presentTiles()
        overlayLayer.contentsScale = scale
        overlayLayer.setNeedsDisplay()
    }

    // Synchronous presents (`presentsWithTransaction`) only while the window is
    // actually being resized — they keep the drawable atomic with the bounds, but
    // block the main thread until the GPU schedules, which is too expensive to pay
    // on every ordinary frame (zoom animation at 120 Hz, scan ticks).
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer.presentsWithTransaction = false
    }

    // MARK: SwiftUI → view

    func apply(controller: ScanController, theme: Theme, version: UInt64, zoomRoot: FSNode?,
               metric: SizeMetric, selection: FSNode?, selectedExt: ExtKey?,
               searchMatchIDs: Set<ObjectIdentifier>, highlightVersion: Int) {
        self.controller = controller
        let oldZoomRoot = self.zoomRoot   // capture before the assignment below (for zoom animation)
        let oldMetric = self.metric

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
            // A pure zoom navigation (from the treemap or the outline) animates the camera;
            // anything else (scan update, metric, theme) relays out instantly.
            if zoomRoot !== oldZoomRoot, let oldRoot = oldZoomRoot, let newRoot = zoomRoot,
               zoomLink == nil, !inLiveResize, !instances.isEmpty,
               startZoomAnimation(from: oldRoot, to: newRoot) {
                overlayLayer.setNeedsDisplay()
            } else if zoomLink != nil, zoomRoot === oldZoomRoot, metric == oldMetric, !themeChanged {
                // Version-only bump (the 10 Hz scan tick, an FSEvents dirty-dot
                // repaint) while the camera animates: defer the relayout to the
                // end of the animation instead of cancelling it — otherwise the
                // push-in can never complete during a live scan.
                pendingRelayout = true
            } else {
                if zoomLink != nil { cancelZoom() }
                relayout()
                presentTiles()
                overlayLayer.setNeedsDisplay()
            }
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
        // A resize mid-zoom (split-divider drag — not a window live-resize) would
        // render the old layout's camera over the new layout: fast-forward to the
        // end state first, then lay out at the new size below.
        if zoomLink != nil { finishZoom() }
        overlayLayer.frame = bounds
        // Backing-layer frame is managed by AppKit; we only resize the drawable + redraw.
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // This frame's present must stay atomic with the bounds change (no
        // band behind a split-divider drag); reverted below unless a window
        // live-resize keeps the synchronous path on.
        metalLayer.presentsWithTransaction = true
        // The squarified layout is now monotone under resize (TreemapLayout freezes the
        // discrete row/orientation/recurse decisions and reruns only continuous geometry),
        // so a full relayout every frame flows smoothly — no freeze/settle needed.
        relayout()
        presentTiles()
        overlayLayer.setNeedsDisplay()
        if !inLiveResize { metalLayer.presentsWithTransaction = false }
    }

    // MARK: Layout (size-dependent placement + colours)

    private func relayout() {
        pendingRelayout = false   // any relayout consumes a deferred one
        hovered = nil
        guard let controller, let zoomRoot, bounds.width > 1, bounds.height > 1 else {
            tiles = []; instances.removeAll(keepingCapacity: true)
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

    /// Rebuild the GPU `instances` from the current tiles. Size is read once per tile
    /// (into `sizeScratch`) and reused for both the max pass and the weight, halving
    /// the atomic loads; `instances` keeps its buffer capacity across frames.
    private func computeColors() {
        let n = tiles.count
        let key = ColorKey(isDark: isDark, version: version)
        if colorKey != key {
            hueIndexCache.removeAll(keepingCapacity: true)
            colorLUT = Array(repeating: nil, count: paletteCount * Self.brightnessBuckets)
            colorKey = key
        }
        if sizeScratch.count < n { sizeScratch = [Int64](repeating: 0, count: n) }
        var maxSize: Int64 = 1
        for i in 0..<n {
            let s = tileSize(tiles[i])
            sizeScratch[i] = s
            if s > maxSize { maxSize = s }
        }
        packInstances(denom: Double(maxSize))
    }

    /// Pack `tiles` into GPU `instances`: world rect on the ground plane
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
                color: tileColor(for: tile, weight: weight)))
        }
    }

    /// sRGB RGBA for a tile, memoised in a bounded `(hueIndex, bucket)` LUT —
    /// no per-frame `NSColor`/hashing on the resize hot path.
    private func tileColor(for tile: TreemapTile, weight: Double) -> SIMD4<Float> {
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
        let ns = NSColor(theme.treemapTypeColor(
            hueIndex: hueIdx, weight: (Double(bucket) + 0.5) / Double(Self.brightnessBuckets)))
        let s = ns.usingColorSpace(.sRGB) ?? ns
        let v = SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), 1)
        colorLUT[lutKey] = v
        return v
    }

    /// Push the current tiles to screen (a GPU render). During a zoom animation
    /// `zoomViewport` overrides the full-bounds camera so the map pushes toward /
    /// pulls back from a folder (same tiles, a moving orthographic camera).
    private func presentTiles() {
        let viewport = zoomViewport ?? CGRect(origin: .zero, size: bounds.size)
        renderer.render(into: metalLayer, instances: instances,
                        camera: Camera.ortho(viewport: viewport),
                        clearColor: backgroundComps, borderColor: borderComps)
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
        // The rects are top-left, so each is flipped into this space at draw time
        // (`flip`). No context or text-matrix flips — so glyphs can never mirror.
        guard layer === overlayLayer else { return }
        drawOverlay(in: ctx, size: layer.bounds.size)
    }

    /// Flip a top-left tile rect into the context's native bottom-left space.
    private func flip(_ r: CGRect, _ height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private func drawOverlay(in ctx: CGContext, size: CGSize) {
        guard zoomLink == nil else { return }   // hidden during a zoom (CG can't follow the Metal camera)
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
    /// layout), so flip Y before hit-testing. Sub-pixel tiles are skipped with the
    /// same 0.5 pt threshold as the renderers — hover/click/menu must never land
    /// on a tile the user can't see. Named to avoid clashing with `NSView.hitTest(_:)`.
    private func tileAt(_ point: CGPoint) -> TreemapTile? {
        let p = CGPoint(x: point.x, y: bounds.height - point.y)
        for tile in tiles.reversed()
        where tile.rect.width > 0.5 && tile.rect.height > 0.5 && tile.rect.contains(p) {
            return tile
        }
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
        guard zoomLink == nil else { return }   // ignore hover while a zoom animates
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
        guard zoomLink == nil else { return }   // let a running zoom animation finish
        let tile = tileAt(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            // Double-click: open a file tile, dive into a folder tile (animated), or pop
            // back out on a leaf/gap — a mouse-only way to zoom.
            guard let controller else { return }
            if let tile {
                if let file = tile.file {
                    if let base = controller.path(for: tile.node) {
                        controller.openItem((base == "/" ? "/" : base + "/") + file.name)
                    }
                } else if tile.node.isDirectory {
                    controller.zoom(into: tile.node)   // apply() animates the transition
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

    // MARK: Animated zoom (a moving orthographic camera)

    private var zoomLink: CADisplayLink?
    private var zoomFrom = CGRect.zero
    private var zoomTo = CGRect.zero
    private var zoomStart: CFTimeInterval = -1
    private var zoomViewport: CGRect?              // nil = full-bounds camera (no animation)
    private var zoomOnDone: (() -> Void)?
    /// A version bump arrived mid-animation; the relayout it asked for runs when
    /// the camera lands (consumed by `relayout()`).
    private var pendingRelayout = false
    private static let zoomDuration: CFTimeInterval = 0.5

    /// Route a zoom navigation (from *any* entry point — treemap double-click, the left
    /// outline, ⌘↑, breadcrumb) into an animated camera move. `apply()` calls this when the
    /// zoom root changed. Returns false when it can't animate (e.g. a sideways jump between
    /// unrelated branches), so the caller falls back to an instant relayout.
    private func startZoomAnimation(from oldRoot: FSNode, to newRoot: FSNode) -> Bool {
        let full = CGRect(origin: .zero, size: bounds.size)
        if isUnder(newRoot, orIs: oldRoot) {
            // Zoom IN: newRoot sits inside the *current* (old) layout, still in `tiles`. Push
            // the camera onto its region, keeping the old tiles; settle to the new layout at end.
            guard let r = regionRect(for: newRoot, in: tiles), r.width > 1, r.height > 1 else { return false }
            animateZoom(from: full, to: r) { [weak self] in self?.settleAfterZoom() }
            return true
        } else if isUnder(oldRoot, orIs: newRoot) {
            // Zoom OUT: lay out the new (parent) view now, then pull the camera back from where
            // the old root sits in it to the full view.
            relayout()
            guard let r = regionRect(for: oldRoot, in: tiles), r.width > 1, r.height > 1 else {
                presentTiles(); overlayLayer.setNeedsDisplay(); return true
            }
            animateZoom(from: r, to: full) { [weak self] in
                self?.presentTiles(); self?.overlayLayer.setNeedsDisplay()
            }
            return true
        }
        return false   // unrelated branches → instant relayout
    }

    private func settleAfterZoom() {
        relayout()
        presentTiles()
        overlayLayer.setNeedsDisplay()
    }

    /// Bounding rect of `ancestor`'s subtree within `tileList` (union of its tiles) — where a
    /// folder sits in a layout, without depending on the (optional) region map being built.
    private func regionRect(for ancestor: FSNode, in tileList: [TreemapTile]) -> CGRect? {
        var union: CGRect?
        for tile in tileList where isUnder(tile.node, orIs: ancestor) {
            union = union.map { $0.union(tile.rect) } ?? tile.rect
        }
        return union
    }

    private func isUnder(_ node: FSNode, orIs ancestor: FSNode) -> Bool {
        var cur: FSNode? = node
        while let n = cur {
            if n === ancestor { return true }
            cur = n.parent
        }
        return false
    }

    private func animateZoom(from: CGRect, to: CGRect, onDone: @escaping () -> Void) {
        zoomFrom = from
        zoomTo = to
        zoomStart = -1
        zoomViewport = from
        zoomOnDone = onDone
        let link = displayLink(target: self, selector: #selector(zoomStep(_:)))
        link.add(to: .main, forMode: .common)
        zoomLink = link
        presentTiles()                      // first frame at `from`
        overlayLayer.setNeedsDisplay()       // clear the CG overlay (it can't follow the camera)
    }

    @objc private func zoomStep(_ link: CADisplayLink) {
        if zoomStart < 0 { zoomStart = link.timestamp }
        let t = min(1, (link.timestamp - zoomStart) / Self.zoomDuration)
        zoomViewport = interpolatedViewport(easeInOut(t))
        presentTiles()
        if t >= 1 { finishZoom() }
    }

    private func finishZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
        zoomViewport = nil
        let done = zoomOnDone
        zoomOnDone = nil
        done?()                             // commit the zoom → apply → relayout → full-view present
        if pendingRelayout {                // deferred scan-tick relayout (zoom-out path doesn't relayout)
            relayout()
            presentTiles()
            overlayLayer.setNeedsDisplay()
        }
    }

    /// Cancel a zoom without committing it (e.g. the view leaves its window mid-animation),
    /// so the `CADisplayLink → self` retain cycle can't outlive the view.
    private func cancelZoom() {
        zoomLink?.invalidate()
        zoomLink = nil
        zoomViewport = nil
        zoomOnDone = nil
    }

    /// Geometric interpolation of the viewport (constant-velocity zoom) between the two
    /// framings, `e` already eased.
    private func interpolatedViewport(_ e: Double) -> CGRect {
        let a = zoomFrom, b = zoomTo
        let aw = max(Double(a.width), 0.5), ah = max(Double(a.height), 0.5)
        let w = aw * pow(Double(b.width) / aw, e)
        let h = ah * pow(Double(b.height) / ah, e)
        let cx = Double(a.midX) + (Double(b.midX) - Double(a.midX)) * e
        let cy = Double(a.midY) + (Double(b.midY) - Double(a.midY)) * e
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
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
        guard zoomLink == nil else { return nil }   // no context menu mid-zoom
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
