import SwiftUI
import AppKit
import Metal
import QuartzCore

/// Treemap view. The map itself is drawn by a plain AppKit `NSView`
/// (`TreemapNSView`) rather than a SwiftUI `Canvas`, so a window resize is driven
/// straight by AppKit — `setFrameSize` → camera update → redraw — with **no**
/// SwiftUI recompute / reconcile / display-list trip per frame. Profiling showed
/// that per-frame SwiftUI machinery, not the drawing, was the resize bottleneck.
///
/// SPEC-10: the tiles live in a persistent *world* (`TreemapWorld`) and the view
/// looks at it through a camera. Resize, pan and zoom are camera moves (no
/// relayout); navigation is map-like (scroll to pan, pinch/wheel to zoom, double
/// click to dive); detail follows the camera (projected-size LOD); and every
/// structural change of the world is morph-animated instead of teleporting.
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
                zoomRequestID: controller.zoomRequestID,
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
/// current observable inputs; the NSView decides what that implies (world sync,
/// camera navigation, or a cheap overlay/dimming redraw).
private struct TreemapRepresentable: NSViewRepresentable {
    let renderer: TreemapMetalRenderer
    let controller: ScanController
    let theme: Theme
    let version: UInt64
    let zoomRoot: FSNode?
    let zoomRequestID: Int
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
                   zoomRequestID: zoomRequestID, metric: metric, selection: selection,
                   selectedExt: selectedExt, searchMatchIDs: searchMatchIDs,
                   highlightVersion: highlightVersion)
        return view
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.onHover = onHover
        view.apply(controller: controller, theme: theme, version: version, zoomRoot: zoomRoot,
                   zoomRequestID: zoomRequestID, metric: metric, selection: selection,
                   selectedExt: selectedExt, searchMatchIDs: searchMatchIDs,
                   highlightVersion: highlightVersion)
    }
}

/// The drawn treemap: an AppKit view AppKit resizes directly. Tiles live in the
/// persistent `TreemapWorld` and are rendered by the GPU into the view's backing
/// `CAMetalLayer` through a camera; the hover outline + selection spotlight live
/// in a CG overlay layer that follows the camera. A camera move (resize, pan,
/// zoom) re-renders with a new matrix — no layout, no instance packing, no
/// allocation. The draw list rebuilds only when the camera leaves the built
/// margin, crosses an LOD threshold, or the data changes — and structural
/// changes morph instead of jumping.
final class TreemapNSView: NSView, CALayerDelegate {
    var onHover: ((HoverInfo?) -> Void)?

    // Inputs (mirrored from SwiftUI via `apply`).
    private var controller: ScanController?
    private var theme = Theme(isDark: true)
    private var version: UInt64 = .max
    private var zoomRoot: FSNode?
    private var zoomRequestID: Int = .min
    private var metric: SizeMetric = .physical
    private var selection: FSNode?
    private var selectedExt: ExtKey?
    private var searchMatchIDs: Set<ObjectIdentifier> = []
    private var highlightVersion: Int = .min
    private var isDark = true

    // The world and the camera (SPEC-10).
    private let world = TreemapWorld()
    private var camera = WorldCamera(rect: .zero)
    /// Camera glued to the world bounds: a resize re-fits instead of preserving scale.
    private var fitMode = true
    private var scanRoot: FSNode?

    // Draw list (world coordinates) & GPU instances (camera-rebased floats).
    private var tiles: [TreemapWorld.Tile] = []
    private var regions: [ObjectIdentifier: CGRect] = [:]
    private var regionsBuilt = false
    private var instances: [TileInstance] = []
    private var rebaseOrigin = CGPoint.zero
    /// World rect the current build covers (visible + margin) and its scale — the
    /// camera can roam inside without a rebuild.
    private var builtRect = CGRect.zero
    private var builtScale: (sx: CGFloat, sy: CGFloat) = (1, 1)
    /// Morph pairing state, keyed by tile identity, in world coordinates.
    /// `lastTargets` is where the previous build put each tile; `lastPrevs` is what
    /// that build was morphing *from* — so a rebuild landing mid-morph can start
    /// from the state actually displayed (lerp of the two at `morphT`), not snap.
    private struct TileState {
        var rect: CGRect
        var color: SIMD4<Float>
    }
    private var lastTargets: [TreemapWorld.TileKey: TileState] = [:]
    private var lastPrevs: [TreemapWorld.TileKey: TileState] = [:]
    private var hovered: TreemapWorld.Tile?

    // Morph clock (structural transitions) + camera animation (navigation fits).
    private var animLink: CADisplayLink?
    private var morphStart: CFTimeInterval = -1
    private var morphT: Float = 1
    private static let morphDuration: CFTimeInterval = 0.22
    private var camFrom = CGRect.zero
    private var camTo = CGRect.zero
    private var camStart: CFTimeInterval = -1
    private var camAnimating = false
    private static let camDuration: CFTimeInterval = 0.5

    /// Debounced camera-settle work: derive the focused folder for the breadcrumb.
    private var focusWork: DispatchWorkItem?
    /// One-shot follow-up when a file listing was still loading during a build.
    private var fileRetryScheduled = false
    private var fileAttempts: [ObjectIdentifier: Int] = [:]

    // Layers.
    private let metalLayer: CAMetalLayer
    private let renderer: TreemapMetalRenderer
    private let overlayLayer = CALayer()

    // MARK: Caches (persist across rebuilds)

    private static let brightnessBuckets = 256
    private let paletteCount = Theme.paletteHues.count
    private var hueIndexCache: [ObjectIdentifier: Int] = [:]
    private var colorLUT: [SIMD4<Float>?] = []
    private var colorKey: ColorKey?
    private var sizeScratch: [Int64] = []

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

    /// Aspect drift (window vs world) beyond which the end of a live resize
    /// re-bakes the world at the new aspect (animated). Below it, the bounded
    /// stretch is kept — decisions stay put.
    private static let aspectHysteresis: CGFloat = 0.10

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
        if window == nil { cancelAnimations() }   // break the CADisplayLink → self cycle on teardown
    }

    private func setScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
        updateDrawableSize()
        presentTiles()
        overlayLayer.contentsScale = scale
        overlayLayer.setNeedsDisplay()
    }

    /// Size the drawable to the view exactly. (A pooled drawable + `contentsRect`
    /// crop was tried per SPEC-10 §3.6 to avoid per-frame IOSurface reallocation
    /// during a drag, but the crop mapping produced black bands — reverted; with
    /// resize now being camera-only, the realloc is the only remaining cost.)
    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1),
                                         height: max(bounds.height * scale, 1))
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
        // Aspect hysteresis: a drag that left the window/world aspects too far
        // apart re-bakes the world at the new aspect — the one global re-decide
        // allowed, and it morphs (SPEC-10 §3.1).
        if fitMode, bounds.height > 1 {
            let viewAspect = bounds.width / bounds.height
            if abs(viewAspect / world.aspect - 1) > Self.aspectHysteresis {
                world.rebake(aspect: viewAspect)
                camera.rect = world.worldBounds
                rebuildTiles(morph: true)
            }
        }
        presentTiles()
        overlayLayer.setNeedsDisplay()
    }

    // MARK: SwiftUI → view

    func apply(controller: ScanController, theme: Theme, version: UInt64, zoomRoot: FSNode?,
               zoomRequestID: Int, metric: SizeMetric, selection: FSNode?, selectedExt: ExtKey?,
               searchMatchIDs: Set<ObjectIdentifier>, highlightVersion: Int) {
        self.controller = controller

        let themeChanged = isDark != theme.isDark
        self.theme = theme
        self.isDark = theme.isDark
        if themeChanged { rebuildThemeColors() }

        // The world's root is the *scan* root — the camera navigates inside it.
        var root = zoomRoot
        while let parent = root?.parent { root = parent }
        let rootChanged = root !== scanRoot

        let dataChanged = version != self.version || metric != self.metric || themeChanged
        let navRequested = zoomRequestID != self.zoomRequestID && self.zoomRequestID != .min
        let firstApply = self.zoomRequestID == .min
        let highlightChanged = selectedExt != self.selectedExt
            || highlightVersion != self.highlightVersion || searchMatchIDs != self.searchMatchIDs
        let selectionChanged = selection !== self.selection

        self.version = version
        self.zoomRoot = zoomRoot
        self.zoomRequestID = zoomRequestID
        self.metric = metric
        self.selectedExt = selectedExt
        self.searchMatchIDs = searchMatchIDs
        self.highlightVersion = highlightVersion
        self.selection = selection
        self.scanRoot = root

        guard let root else {
            tiles = []; instances = []; regions = [:]; regionsBuilt = false
            renderer.upload(instances: [], previous: nil)
            presentTiles()
            overlayLayer.setNeedsDisplay()
            return
        }
        world.sync(root: root, metric: metric, version: version)

        if rootChanged || firstApply {
            // A new scan (or first appearance): fresh world, camera at fit.
            cancelAnimations()
            fitMode = true
            if bounds.width > 1, bounds.height > 1 {
                let viewAspect = bounds.width / bounds.height
                if abs(viewAspect / world.aspect - 1) > Self.aspectHysteresis {
                    world.rebake(aspect: viewAspect)
                }
            }
            camera.rect = world.worldBounds
            rebuildTiles(morph: false)
            presentTiles()
            overlayLayer.setNeedsDisplay()
            return
        }

        if dataChanged {
            // Scan tick / FSEvents refresh / metric change: entries revalidate
            // lazily (ε-local), and whatever moved morphs (SPEC-10 §3.4). A pure
            // theme change only recolours — no motion to animate.
            rebuildTiles(morph: !themeChanged)
            presentTiles()
            overlayLayer.setNeedsDisplay()
        }

        if navRequested, let target = zoomRoot {
            // Explicit navigation (double-click, outline, breadcrumb, ⌘↑): an
            // animated camera fit — the world does not move.
            if let rect = world.worldRect(of: target, root: root) {
                animateCamera(to: target === root ? world.worldBounds : fitTarget(for: rect))
                fitMode = target === root
            }
        }

        if !dataChanged {
            if selectionChanged && selection != nil && !regionsBuilt {
                rebuildTiles(morph: false)   // need the region map to outline the new selection
                presentTiles()
            } else if highlightChanged {
                repackInstances()            // dimming changed; rects unchanged → repack
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

    // MARK: Resize (AppKit-driven — now a camera move)

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        let changed = newSize != oldSize
        super.setFrameSize(newSize)
        guard changed else { return }
        overlayLayer.frame = bounds
        updateDrawableSize()
        // This frame's present must stay atomic with the bounds change (no
        // band behind a split-divider drag); reverted below unless a window
        // live-resize keeps the synchronous path on.
        metalLayer.presentsWithTransaction = true
        if fitMode {
            camera.rect = world.worldBounds
        } else if oldSize.width > 1, oldSize.height > 1 {
            // Free camera: keep the scale, reveal more/less world (map-window feel).
            let cx = camera.rect.midX, cy = camera.rect.midY
            let w = camera.rect.width * newSize.width / oldSize.width
            let h = camera.rect.height * newSize.height / oldSize.height
            camera.rect = clampedViewport(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        }
        maybeRebuild()
        presentTiles()
        overlayLayer.setNeedsDisplay()
        if !inLiveResize { metalLayer.presentsWithTransaction = false }
    }

    // MARK: World → GPU (the only non-camera work)

    /// Rebuild the LOD tile set for the current camera and pack it into GPU
    /// instances. `morph` pairs each tile with its previous world rect (or its
    /// nearest ancestor's) and animates the transition.
    private func rebuildTiles(morph: Bool) {
        guard let controller, let root = scanRoot, bounds.width > 1, bounds.height > 1,
              camera.rect.width > 0, camera.rect.height > 0 else {
            tiles = []; instances = []; regions = [:]; regionsBuilt = false
            lastTargets = [:]; lastPrevs = [:]
            renderer.upload(instances: [], previous: nil)
            return
        }
        hovered = nil
        let scale = camera.scale(viewSize: bounds.size)
        let needsRegions = selection != nil
        let result = world.build(root: root, visible: camera.rect, scale: scale,
                                 needsRegions: needsRegions, files: { [weak self] node in
            self?.fileTiles(for: node, controller: controller)
        })
        tiles = result.tiles
        regions = result.regions
        regionsBuilt = needsRegions
        builtRect = camera.rect.insetBy(dx: -camera.rect.width * TreemapWorld.buildMargin,
                                        dy: -camera.rect.height * TreemapWorld.buildMargin)
        builtScale = scale
        if result.pendingFiles { scheduleFileRetry() }

        // Morph pairing: a tile that existed in the previous build slides from
        // the state it was *actually displaying* (mid-morph aware) and cross-fades
        // its colour (the brightness renormalisation stops popping). A tile that
        // didn't exist appears at its final place — no geometric "growth", which
        // overlapped neighbours and read as giant squares during a zoom.
        let doMorph = morph && !lastTargets.isEmpty && !inLiveResize
        packInstances()
        var previous: [TileInstance]? = nil
        if doMorph {
            let t = morphT
            var prev = instances
            for i in tiles.indices {
                guard let target = lastTargets[TreemapWorld.TileKey(tiles[i])] else { continue }
                var from = target
                if t < 1, let p = lastPrevs[TreemapWorld.TileKey(tiles[i])] {
                    from.rect = lerp(p.rect, target.rect, CGFloat(t))
                    from.color = p.color + (target.color - p.color) * t
                }
                prev[i].origin.x = Float(from.rect.minX - rebaseOrigin.x)
                prev[i].origin.z = Float(from.rect.minY - rebaseOrigin.y)
                prev[i].size.x = Float(from.rect.width)
                prev[i].size.z = Float(from.rect.height)
                prev[i].color = from.color
            }
            previous = prev
        }
        recordMorphState(previous: previous)

        renderer.upload(instances: instances, previous: previous)
        if previous != nil { startMorph() } else { morphT = 1 }
    }

    /// Snapshot the pairing dictionaries for the *next* rebuild.
    private func recordMorphState(previous: [TileInstance]?) {
        var targets: [TreemapWorld.TileKey: TileState] = [:]
        targets.reserveCapacity(tiles.count)
        var prevs: [TreemapWorld.TileKey: TileState] = [:]
        if previous != nil { prevs.reserveCapacity(tiles.count) }
        for i in tiles.indices {
            let key = TreemapWorld.TileKey(tiles[i])
            targets[key] = TileState(rect: tiles[i].rect, color: instances[i].color)
            if let previous {
                let p = previous[i]
                prevs[key] = TileState(
                    rect: CGRect(x: CGFloat(p.origin.x) + rebaseOrigin.x,
                                 y: CGFloat(p.origin.z) + rebaseOrigin.y,
                                 width: CGFloat(p.size.x), height: CGFloat(p.size.z)),
                    color: p.color)
            }
        }
        lastTargets = targets
        lastPrevs = prevs
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    /// Rebuild the camera-dependent parts only when the camera leaves the built
    /// margin or its scale drifts past the LOD band. Pure camera frames skip this.
    private func maybeRebuild() {
        guard scanRoot != nil else { return }
        guard builtRect.width > 0 else {
            // Nothing built yet (the first apply ran before the view had a size).
            rebuildTiles(morph: false)
            return
        }
        let scale = camera.scale(viewSize: bounds.size)
        let scaleDrift = max(scale.sx / builtScale.sx, scale.sy / builtScale.sy)
        let outgrown = !builtRect.contains(camera.rect)
        if outgrown || scaleDrift > 1.3 || scaleDrift < 0.77 {
            // Morph on zoom-driven rebuilds (LOD splits/merges — the Maps feel);
            // pan-driven edge fills appear instantly.
            rebuildTiles(morph: scaleDrift > 1.3 || scaleDrift < 0.77)
        }
    }

    /// Pack `tiles` into GPU `instances`: camera-rebased world rect on the ground
    /// plane (Float precision holds because coordinates are relative to the built
    /// visible rect — the floating origin), packed sRGB colour, dim folded in.
    private func packInstances() {
        let n = tiles.count
        rebaseOrigin = builtRect.origin
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
        let denom = Double(maxSize)
        let highlightName = selectedExt?.displayName
        let hasSearch = highlightName == nil && !searchMatchIDs.isEmpty
        instances.removeAll(keepingCapacity: true)
        instances.reserveCapacity(n)
        for i in 0..<n {
            let tile = tiles[i]
            let r = tile.rect
            let weight = min(1.0, max(0.0, pow(Double(sizeScratch[i]) / denom, 0.40)))
            var dim: Float = 0
            if let highlightName {
                let tileExt = tile.file?.extName ?? tile.node.dominantExt.displayName
                if tileExt != highlightName { dim = 1 }
            } else if hasSearch, !isUnderMatch(tile.node) {
                dim = 1
            }
            instances.append(TileInstance(
                origin: SIMD4<Float>(Float(r.minX - rebaseOrigin.x), 0, Float(r.minY - rebaseOrigin.y), 0),
                size: SIMD4<Float>(Float(r.width), 0, Float(r.height), dim),
                color: tileColor(for: tile, weight: weight)))
        }
    }

    /// Highlight/search change: same tiles, new dims — repack and re-upload.
    private func repackInstances() {
        packInstances()
        renderer.upload(instances: instances, previous: nil)
        morphT = 1
        recordMorphState(previous: nil)   // future morphs fade from the new colours
    }

    private func tileSize(_ tile: TreemapWorld.Tile) -> Int64 {
        if let file = tile.file { return file.size }
        return tile.isFileBlock ? tile.node.directFilesSize(metric) : tile.node.size(metric)
    }

    /// File tiles for a folder whose block crossed the file-LOD threshold.
    /// `nil` = listing still loading (a one-shot rebuild retries shortly).
    private func fileTiles(for node: FSNode, controller: ScanController) -> [FileTileInfo]? {
        guard controller.isHostScan, !controller.isScanning else { return [] }
        let items = controller.filesIn(node)
        if items.isEmpty && node.directFileCount > 0 {
            let id = ObjectIdentifier(node)
            let attempts = fileAttempts[id, default: 0]
            if attempts < 3 {
                fileAttempts[id] = attempts + 1
                return nil   // in flight
            }
            return []        // failed/blocked: keep the aggregate block
        }
        return items.map {
            FileTileInfo(name: $0.name, size: $0.size(metric), extName: OutlineRowView.extDisplay($0.name))
        }
    }

    private func scheduleFileRetry() {
        guard !fileRetryScheduled else { return }
        fileRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.fileRetryScheduled = false
            self.rebuildTiles(morph: true)
            self.presentTiles()
        }
    }

    /// sRGB RGBA for a tile, memoised in a bounded `(hueIndex, bucket)` LUT —
    /// no per-frame `NSColor`/hashing on the hot path.
    private func tileColor(for tile: TreemapWorld.Tile, weight: Double) -> SIMD4<Float> {
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

    /// Push the current world to screen through the camera — a pure GPU render.
    private func presentTiles() {
        let viewport = camera.rect.offsetBy(dx: -rebaseOrigin.x, dy: -rebaseOrigin.y)
        renderer.draw(into: metalLayer,
                      camera: Camera.ortho(viewport: viewport),
                      pointsPerUnit: camera.scale(viewSize: bounds.size),
                      morph: morphT,
                      clearColor: backgroundComps,
                      borderColor: borderComps)
    }

    // MARK: Camera navigation (SPEC-10 M2 — the map)

    /// Expand a node's rect to the world aspect (the camera rect's invariant
    /// aspect), so a navigation fit never changes the on-screen stretch.
    private func fitTarget(for rect: CGRect) -> CGRect {
        let aspect = world.aspect
        var w = rect.width, h = rect.height
        if w / h > aspect { h = w / aspect } else { w = h * aspect }
        // Slight breathing room around the target folder.
        w *= 1.02; h *= 1.02
        return clampedViewport(CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }

    /// Keep the viewport inside the world (when smaller) and snap to fit (when
    /// it would exceed it). Also bounds the zoom-in so Double math stays sane.
    private func clampedViewport(_ rect: CGRect) -> CGRect {
        var r = rect
        let wb = world.worldBounds
        let minW = wb.width / 1_000_000
        if r.width < minW {
            let f = minW / r.width
            r = CGRect(x: r.midX - r.width * f / 2, y: r.midY - r.height * f / 2,
                       width: r.width * f, height: r.height * f)
        }
        if r.width >= wb.width || r.height >= wb.height {
            return wb
        }
        if r.minX < wb.minX { r.origin.x = wb.minX }
        if r.minY < wb.minY { r.origin.y = wb.minY }
        if r.maxX > wb.maxX { r.origin.x = wb.maxX - r.width }
        if r.maxY > wb.maxY { r.origin.y = wb.maxY - r.height }
        return r
    }

    override func scrollWheel(with event: NSEvent) {
        guard scanRoot != nil else { return }
        let isGesture = event.phase != [] || event.momentumPhase != []
        if isGesture {
            // Trackpad: two-finger pan — the content follows the fingers
            // (`scrollingDelta` already folds in the natural-scrolling preference).
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            camera.pan(byView: delta, viewSize: bounds.size)
            camera.rect = clampedViewport(camera.rect)
            fitMode = camera.rect == world.worldBounds
        } else {
            // Mouse wheel: zoom toward the cursor (the Maps convention). Precise
            // devices report pixel deltas (±tens per notch) where a classic wheel
            // reports lines (±1–3): normalise to "steps" and bound the per-event
            // factor so one notch is a smooth ×1.15, never a teleport.
            guard event.scrollingDeltaY != 0 else { return }
            let steps = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 12
                : event.scrollingDeltaY
            let factor = min(2.0, max(0.5, pow(1.15, steps)))
            zoomCamera(by: factor, anchor: topLeftPoint(event))
        }
        cameraMoved()
    }

    override func magnify(with event: NSEvent) {
        guard scanRoot != nil else { return }
        zoomCamera(by: 1 + event.magnification, anchor: topLeftPoint(event))
        cameraMoved()
    }

    private func zoomCamera(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        camera.zoom(by: factor, anchorView: anchor, viewSize: bounds.size)
        camera.rect = clampedViewport(camera.rect)
        fitMode = camera.rect == world.worldBounds
    }

    /// Common postlude of every interactive camera move.
    private func cameraMoved() {
        camAnimating = false
        maybeRebuild()
        presentTiles()
        overlayLayer.setNeedsDisplay()
        scheduleFocusDerivation()
    }

    /// After the camera settles, derive the deepest folder containing the view —
    /// the breadcrumb/list follow the map (`zoomRoot` as a derived value).
    private func scheduleFocusDerivation() {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let controller = self.controller, let root = self.scanRoot else { return }
            let focus = self.world.focusNode(root: root, visible: self.camera.rect)
            if focus !== controller.zoomRoot { controller.cameraDidFocus(focus) }
        }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Mouse location in top-left view coordinates (the world's orientation).
    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    // MARK: Animation clock (camera fits + morphs share one link)

    private func animateCamera(to target: CGRect) {
        camFrom = camera.rect
        camTo = target
        camStart = -1
        camAnimating = true
        ensureLink()
    }

    private func startMorph() {
        morphT = 0
        morphStart = -1
        ensureLink()
    }

    private func ensureLink() {
        guard animLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(animStep(_:)))
        link.add(to: .main, forMode: .common)
        animLink = link
    }

    @objc private func animStep(_ link: CADisplayLink) {
        var active = false
        if camAnimating {
            if camStart < 0 { camStart = link.timestamp }
            let t = min(1, (link.timestamp - camStart) / Self.camDuration)
            camera.rect = interpolatedViewport(easeInOut(t))
            if t >= 1 {
                camAnimating = false
                camera.rect = camTo
                fitMode = camera.rect == world.worldBounds
                maybeRebuild()
                overlayLayer.setNeedsDisplay()
                scheduleFocusDerivation()
            } else {
                active = true
            }
        }
        if morphT < 1 {
            if morphStart < 0 { morphStart = link.timestamp }
            let t = min(1, (link.timestamp - morphStart) / Self.morphDuration)
            morphT = Float(easeInOut(t))
            if t < 1 { active = true }
        }
        presentTiles()
        if !active {
            animLink?.invalidate()
            animLink = nil
        }
    }

    private func cancelAnimations() {
        animLink?.invalidate()
        animLink = nil
        camAnimating = false
        morphT = 1
        focusWork?.cancel()
    }

    /// Geometric interpolation of the viewport (constant-velocity zoom) between the
    /// two framings, `e` already eased.
    private func interpolatedViewport(_ e: Double) -> CGRect {
        let a = camFrom, b = camTo
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

    // MARK: Drawing (CG overlay — follows the camera)

    func draw(_ layer: CALayer, in ctx: CGContext) {
        // The layer context is native Core Graphics: bottom-left, y-up, text upright.
        // World rects are converted to top-left view coordinates via the camera,
        // then flipped into this space at draw time (`flip`).
        guard layer === overlayLayer else { return }
        drawOverlay(in: ctx, size: layer.bounds.size)
    }

    /// Flip a top-left view rect into the context's native bottom-left space.
    private func flip(_ r: CGRect, _ height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    private func drawOverlay(in ctx: CGContext, size: CGSize) {
        guard !camAnimating else { return }   // redrawn when the camera lands
        if let selection, let sel = selectionRect(for: selection),
           case let r = flip(camera.worldToView(sel, viewSize: bounds.size), size.height),
           r.intersects(CGRect(origin: .zero, size: size)) {
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
            let r = flip(camera.worldToView(hovered.rect, viewSize: bounds.size), size.height)
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

    /// Bounding region of a directory in the current build, falling back to the
    /// nearest ancestor that has one (the tile it visually lives inside).
    private func selectionRect(for node: FSNode) -> CGRect? {
        var cur: FSNode? = node
        while let n = cur {
            if let r = regions[ObjectIdentifier(n)] {
                // Selecting the whole visible world would spotlight everything: skip.
                return r.contains(camera.rect) ? nil : r
            }
            cur = n.parent
        }
        return nil
    }

    // MARK: Hit testing & interaction

    /// The topmost tile at `point` (a mouse location in view coordinates). Mouse
    /// coordinates arrive bottom-left; the camera converts to world space. Tiles
    /// below the sub-pixel cull can't be hit — hover/click/menu must never land
    /// on a tile the user can't see. Named to avoid clashing with `NSView.hitTest(_:)`.
    private func tileAt(_ point: CGPoint) -> TreemapWorld.Tile? {
        let pTop = CGPoint(x: point.x, y: bounds.height - point.y)
        let p = camera.viewToWorld(pTop, viewSize: bounds.size)
        for tile in tiles.reversed() where tile.rect.contains(p) {
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
        guard !camAnimating else { return }   // ignore hover while the camera flies
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
        guard !camAnimating else { return }   // let a running camera flight finish
        let tile = tileAt(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            // Double-click: open a file tile, dive into a folder tile (an animated
            // camera fit via the controller round-trip), or pull back on a leaf/gap.
            guard let controller else { return }
            if let tile {
                if let file = tile.file {
                    if let base = controller.path(for: tile.node) {
                        controller.openItem((base == "/" ? "/" : base + "/") + file.name)
                    }
                } else if tile.node.isDirectory {
                    controller.zoom(into: tile.node)   // apply() flies the camera there
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

    private func hoverInfo(for tile: TreemapWorld.Tile) -> HoverInfo {
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
        guard !camAnimating else { return nil }   // no context menu mid-flight
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
