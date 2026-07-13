import SwiftUI
import AppKit
import Metal
import QuartzCore

/// Sunburst view (SPEC-13) — the polar projection of the same scan the treemap
/// draws. It reads the *same* `ScanController` observables (tree, version,
/// zoom root, selection, highlight, search), so switching between the two map
/// modes never re-scans and keeps the navigation state; only the geometry
/// changes: depth becomes concentric rings, size becomes angular extent, and
/// the current zoom root becomes the hole in the middle (its total inside).
///
/// Interaction parity with the treemap: hover pill, click to select/reveal,
/// double-click to dive (re-roots the wheel, morph-animated), double-click the
/// hole or the background to pull back, scroll to pan, pinch/wheel to zoom
/// toward the cursor, right-click menu, search/type-highlight dimming and the
/// selection spotlight.
struct SunburstView: View {
    @Bindable var controller: ScanController
    @Environment(\.theme) private var theme
    @State private var hoverModel = HoverModel()

    /// The one GPU renderer, built once per process and shared across view
    /// recreations (the shader is compiled at launch). `nil` = Metal unusable:
    /// explicit failure state, same policy as the treemap.
    private static let sharedRenderer = SunburstMetalRenderer()

    var body: some View {
        if let renderer = Self.sharedRenderer {
            SunburstRepresentable(
                renderer: renderer,
                controller: controller,
                theme: theme,
                version: controller.version,
                zoomRoot: controller.zoomRoot,
                zoomRequestID: controller.zoomRequestID,
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
            .accessibilityLabel("Sunburst")
            .accessibilityValue(mapAccessibilitySummary(controller))
        } else {
            MapUnavailableView()
        }
    }
}

/// Bridges the AppKit `SunburstNSView` into SwiftUI — same contract as the
/// treemap's representable: `updateNSView` pushes the observable inputs, the
/// NSView decides what that implies.
private struct SunburstRepresentable: NSViewRepresentable {
    let renderer: SunburstMetalRenderer
    let controller: ScanController
    let theme: Theme
    let version: UInt64
    let zoomRoot: FSNode?
    let zoomRequestID: Int
    let selection: FSNode?
    let selectedExt: ExtKey?
    let searchMatchIDs: Set<ObjectIdentifier>
    let highlightVersion: Int
    let isDark: Bool
    let onHover: (HoverInfo?) -> Void

    func makeNSView(context: Context) -> SunburstNSView {
        let view = SunburstNSView(renderer: renderer)
        view.onHover = onHover
        view.apply(controller: controller, theme: theme, version: version, zoomRoot: zoomRoot,
                   zoomRequestID: zoomRequestID, selection: selection,
                   selectedExt: selectedExt, searchMatchIDs: searchMatchIDs,
                   highlightVersion: highlightVersion)
        return view
    }

    func updateNSView(_ view: SunburstNSView, context: Context) {
        view.onHover = onHover
        view.apply(controller: controller, theme: theme, version: version, zoomRoot: zoomRoot,
                   zoomRequestID: zoomRequestID, selection: selection,
                   selectedExt: selectedExt, searchMatchIDs: searchMatchIDs,
                   highlightVersion: highlightVersion)
    }
}

/// The drawn sunburst: arcs live in the persistent `SunburstWorld` and are
/// rendered by the GPU through a camera; hover/selection outlines and the
/// centre label live in a CG overlay that follows the camera. Camera moves are
/// matrix-only frames; the arc set rebuilds only when the camera leaves the
/// built margin, crosses an LOD band, or the data/root changes — and
/// structural changes morph (angles and radii interpolate) instead of jumping.
///
/// One deliberate difference from the treemap: the camera is **isotropic**
/// (circles must stay circles), so the viewport letterboxes the square world
/// instead of stretching with the window, and there is no aspect re-bake. And
/// `zoomRoot` is not derived from the camera — the wheel re-roots explicitly
/// (double-click, breadcrumb, outline), the camera is free inspection on top.
final class SunburstNSView: NSView, CALayerDelegate {
    var onHover: ((HoverInfo?) -> Void)?

    // Inputs (mirrored from SwiftUI via `apply`).
    private var controller: ScanController?
    private var theme = Theme(isDark: true)
    private var version: UInt64 = .max
    private var zoomRoot: FSNode?
    private var zoomRequestID: Int = .min
    private var selection: FSNode?
    private var selectedExt: ExtKey?
    private var searchMatchIDs: Set<ObjectIdentifier> = []
    private var highlightVersion: Int = .min
    private var isDark = true

    // The world and the camera.
    private let world = SunburstWorld()
    private var camera = WorldCamera(rect: .zero)
    /// Camera glued to the letterboxed fit: a resize re-fits instead of
    /// preserving scale.
    private var fitMode = true
    private var scanRoot: FSNode?
    /// The wheel's layout root (= the controller's zoom root).
    private var displayRoot: FSNode?

    // Draw list (world terms) & GPU instances (camera-rebased floats).
    private var arcs: [SunburstWorld.Arc] = []
    private var arcBoundsScratch: [CGRect] = []
    private var instances: [ArcInstance] = []
    private var rebaseOrigin = CGPoint.zero
    private var builtRect = CGRect.zero
    private var builtScale: CGFloat = 1
    /// Morph pairing state, keyed by arc identity, in absolute polar terms.
    private struct ArcState {
        var a0: Double
        var a1: Double
        var r0: CGFloat
        var r1: CGFloat
        var color: SIMD4<Float>
    }
    private var lastTargets: [SunburstWorld.ArcKey: ArcState] = [:]
    private var lastPrevs: [SunburstWorld.ArcKey: ArcState] = [:]
    private var hovered: SunburstWorld.Arc?
    private var hoveredHole = false

    // Morph clock (structural transitions) + camera animation (navigation fits).
    private var animLink: CADisplayLink?
    private var morphStart: CFTimeInterval = -1
    private var morphT: Float = 1
    private static let morphDuration: CFTimeInterval = 0.32
    private var camFrom = CGRect.zero
    private var camTo = CGRect.zero
    private var camStart: CFTimeInterval = -1
    private var camAnimating = false
    private static let camDuration: CFTimeInterval = 0.5

    /// One-shot follow-up when a file listing was still loading during a build.
    private var fileRetryScheduled = false
    private var fileAttempts: [ObjectIdentifier: Int] = [:]

    // Layers.
    private let metalLayer: CAMetalLayer
    private let renderer: SunburstMetalRenderer
    private let overlayLayer = CALayer()

    // MARK: Caches (persist across rebuilds — same scheme as the treemap)

    private static let brightnessBuckets = 256
    private let paletteCount = Theme.paletteHues.count
    private var hueIndexCache: [ObjectIdentifier: Int] = [:]
    private var colorLUT: [SIMD4<Float>?] = []
    private var colorKey: ColorKey?
    private var sizeScratch: [Int64] = []

    // Theme-derived colours for the overlay + Metal uniforms.
    private var backgroundCG = CGColor(gray: 0, alpha: 1)
    private var accentShadowCG = CGColor(gray: 0.3, alpha: 0.9)
    private var panelCG = CGColor(gray: 0.1, alpha: 1)
    private var separatorCG = CGColor(gray: 1, alpha: 0.1)
    private var textPrimaryCG = CGColor(gray: 1, alpha: 1)
    private var textSecondaryCG = CGColor(gray: 0.7, alpha: 1)
    private var backgroundComps = SIMD4<Float>(0, 0, 0, 1)
    private var borderComps = SIMD4<Float>(0, 0, 0, 0.45)
    private static let spotlightDimCG = CGColor(gray: 0, alpha: 0.5)
    private static let blackBorderCG = CGColor(gray: 0, alpha: 0.85)
    private static let whiteCG = CGColor(gray: 1, alpha: 1)
    private static let hoverCG = CGColor(gray: 1, alpha: 0.95)

    private struct ColorKey: Equatable { let isDark: Bool; let version: UInt64 }

    // MARK: Setup

    init(renderer: SunburstMetalRenderer) {
        self.renderer = renderer
        let ml = CAMetalLayer()
        ml.device = renderer.device
        ml.pixelFormat = .bgra8Unorm            // non-sRGB: arc colours are already sRGB-encoded
        ml.framebufferOnly = true
        ml.isOpaque = true
        ml.presentsWithTransaction = false      // turned on only while resizing
        ml.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        self.metalLayer = ml
        super.init(frame: .zero)
        wantsLayer = true
        // Backing-layer setup identical to the treemap: AppKit resizes the
        // CAMetalLayer in lockstep with the view; the overlay sits above it.
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true

        overlayLayer.delegate = self
        overlayLayer.needsDisplayOnBoundsChange = true
        overlayLayer.contentsScale = 2
        overlayLayer.frame = bounds
        layer?.addSublayer(overlayLayer)

        rebuildThemeColors()
    }

    override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard !inLiveResize else { return }
        setScale(window?.backingScaleFactor ?? 2)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelAnimations() }
    }

    private func setScale(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
        updateDrawableSize()
        presentArcs()
        overlayLayer.contentsScale = scale
        overlayLayer.setNeedsDisplay()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1),
                                         height: max(bounds.height * scale, 1))
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer.presentsWithTransaction = false
        // No aspect re-bake here — the disc is aspect-free; the camera
        // letterboxed all along.
        presentArcs()
        overlayLayer.setNeedsDisplay()
    }

    // MARK: SwiftUI → view

    func apply(controller: ScanController, theme: Theme, version: UInt64, zoomRoot: FSNode?,
               zoomRequestID: Int, selection: FSNode?, selectedExt: ExtKey?,
               searchMatchIDs: Set<ObjectIdentifier>, highlightVersion: Int) {
        self.controller = controller

        let themeChanged = isDark != theme.isDark
        self.theme = theme
        self.isDark = theme.isDark
        if themeChanged { rebuildThemeColors() }

        // The world's cache root is the *scan* root; the wheel is laid out from
        // the zoom root (the hole).
        var root = zoomRoot
        while let parent = root?.parent { root = parent }
        let rootChanged = root !== scanRoot

        let dataChanged = version != self.version || themeChanged
        let navRequested = zoomRequestID != self.zoomRequestID && self.zoomRequestID != .min
        let firstApply = self.zoomRequestID == .min
        let rootMoved = zoomRoot !== displayRoot
        let highlightChanged = selectedExt != self.selectedExt
            || highlightVersion != self.highlightVersion || searchMatchIDs != self.searchMatchIDs
        let selectionChanged = selection !== self.selection

        self.version = version
        self.zoomRoot = zoomRoot
        self.zoomRequestID = zoomRequestID
        self.selectedExt = selectedExt
        self.searchMatchIDs = searchMatchIDs
        self.highlightVersion = highlightVersion
        self.selection = selection
        self.scanRoot = root
        self.displayRoot = zoomRoot

        guard let root, zoomRoot != nil else {
            arcs = []; instances = []
            lastTargets = [:]; lastPrevs = [:]
            renderer.upload(instances: [], previous: nil)
            presentArcs()
            overlayLayer.setNeedsDisplay()
            return
        }
        world.sync(root: root, version: version)

        if rootChanged || firstApply {
            // A new scan (or first appearance): fresh camera at fit.
            cancelAnimations()
            fitMode = true
            camera.rect = fitRect(bounds.size)
            rebuildArcs(morph: false)
            presentArcs()
            overlayLayer.setNeedsDisplay()
            return
        }

        if dataChanged || rootMoved {
            // Data tick → same policy as the treemap: morph in calm life,
            // teleport during a live scan. A re-root (dive/pull-back) is the
            // signature animation: shared arcs sweep to their new spans.
            rebuildArcs(morph: !themeChanged && !controller.isScanning)
            presentArcs()
            overlayLayer.setNeedsDisplay()
        }

        if navRequested {
            // Explicit navigation: fly the camera back to the letterboxed fit —
            // the wheel itself re-centred via the rebuild above.
            let fit = fitRect(bounds.size)
            if camera.rect != fit {
                animateCamera(to: fit)
            }
            fitMode = true
        }

        if !dataChanged && !rootMoved {
            if highlightChanged {
                repackInstances()            // dimming changed; geometry unchanged
                presentArcs()
            }
            if selectionChanged { overlayLayer.setNeedsDisplay() }
        }
    }

    private func rebuildThemeColors() {
        backgroundCG = NSColor(theme.treemapBackground).cgColor
        accentShadowCG = NSColor(theme.accent).withAlphaComponent(0.9).cgColor
        panelCG = NSColor(theme.panelBackground).cgColor
        separatorCG = NSColor(theme.separator).cgColor
        textPrimaryCG = NSColor(theme.textPrimary).cgColor
        textSecondaryCG = NSColor(theme.textSecondary).cgColor
        layer?.backgroundColor = backgroundCG
        backgroundComps = srgbComps(theme.treemapBackground)
        borderComps = srgbComps(theme.treemapBorder)
    }

    private func srgbComps(_ color: Color) -> SIMD4<Float> {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return SIMD4<Float>(Float(ns.redComponent), Float(ns.greenComponent),
                            Float(ns.blueComponent), Float(ns.alphaComponent))
    }

    // MARK: Camera (isotropic — circles stay circles)

    /// Points per world unit. One number: the viewport always has the view's
    /// aspect, so the two axes scale identically.
    private var cameraScale: CGFloat {
        guard camera.rect.width > 0 else { return 1 }
        return bounds.width / camera.rect.width
    }

    /// The smallest viewport with the view's aspect that contains the whole
    /// (square) world, centred — the sunburst's "fit" framing. Letterboxing in
    /// world coordinates is what keeps the mapping isotropic at any window shape.
    private func fitRect(_ viewSize: CGSize) -> CGRect {
        let wb = world.worldBounds
        guard viewSize.width > 1, viewSize.height > 1 else { return wb }
        let aspect = viewSize.width / viewSize.height
        var w = wb.width, h = wb.height
        if aspect >= 1 { w = h * aspect } else { h = w / aspect }
        return CGRect(x: wb.midX - w / 2, y: wb.midY - h / 2, width: w, height: h)
    }

    /// Keep the viewport inside the fit framing (when smaller) and snap to fit
    /// (when it would exceed it). Also bounds the zoom-in so Double math stays sane.
    private func clampedViewport(_ rect: CGRect) -> CGRect {
        var r = rect
        let fit = fitRect(bounds.size)
        let minW = fit.width / 1_000_000
        if r.width < minW {
            let f = minW / r.width
            r = CGRect(x: r.midX - r.width * f / 2, y: r.midY - r.height * f / 2,
                       width: r.width * f, height: r.height * f)
        }
        if r.width >= fit.width || r.height >= fit.height {
            return fit
        }
        if r.minX < fit.minX { r.origin.x = fit.minX }
        if r.minY < fit.minY { r.origin.y = fit.minY }
        if r.maxX > fit.maxX { r.origin.x = fit.maxX - r.width }
        if r.maxY > fit.maxY { r.origin.y = fit.maxY - r.height }
        return r
    }

    // MARK: Resize (AppKit-driven — a camera move, never a re-layout)

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        let changed = newSize != oldSize
        super.setFrameSize(newSize)
        guard changed else { return }
        overlayLayer.frame = bounds
        updateDrawableSize()
        metalLayer.presentsWithTransaction = true
        if fitMode {
            camera.rect = fitRect(newSize)
        } else if oldSize.width > 1, oldSize.height > 1 {
            // Free camera: keep the scale, reveal more/less world. Scaling both
            // axes by their view ratio preserves the aspect equality (isotropy).
            let cx = camera.rect.midX, cy = camera.rect.midY
            let w = camera.rect.width * newSize.width / oldSize.width
            let h = camera.rect.height * newSize.height / oldSize.height
            camera.rect = clampedViewport(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        }
        maybeRebuild()
        presentArcs()
        overlayLayer.setNeedsDisplay()
        if !inLiveResize { metalLayer.presentsWithTransaction = false }
    }

    // MARK: World → GPU (the only non-camera work)

    /// Rebuild the LOD arc set for the current camera and pack it into GPU
    /// instances. `morph` pairs each arc with its previous polar state and
    /// animates the transition (scan ticks, refreshes, re-roots, LOD splits).
    private func rebuildArcs(morph: Bool) {
        guard let controller, let displayRoot, bounds.width > 1, bounds.height > 1,
              camera.rect.width > 0, camera.rect.height > 0 else {
            arcs = []; instances = []
            lastTargets = [:]; lastPrevs = [:]
            renderer.upload(instances: [], previous: nil)
            return
        }
        hovered = nil
        hoveredHole = false
        let scale = cameraScale
        let result = world.build(root: displayRoot, visible: camera.rect, scale: scale,
                                 needsSpans: false, files: { [weak self] node in
            self?.fileArcs(for: node, controller: controller)
        })
        arcs = result.arcs
        builtRect = camera.rect.insetBy(dx: -camera.rect.width * SunburstWorld.buildMargin,
                                        dy: -camera.rect.height * SunburstWorld.buildMargin)
        builtScale = scale
        if result.pendingFiles { scheduleFileRetry() }

        // Morph pairing: an arc that existed in the previous build sweeps from
        // the state it was *actually displaying* (mid-morph aware) and
        // cross-fades its colour. An arc that didn't exist appears in place.
        let doMorph = morph && !lastTargets.isEmpty && !inLiveResize
        packInstances()
        var previous: [ArcInstance]? = nil
        if doMorph {
            let t = morphT
            var prev = instances
            for i in arcs.indices {
                let key = SunburstWorld.ArcKey(arcs[i])
                guard let target = lastTargets[key] else { continue }
                var from = target
                if t < 1, let p = lastPrevs[key] {
                    let ct = CGFloat(t), dt = Double(t)
                    from.a0 = p.a0 + (target.a0 - p.a0) * dt
                    from.a1 = p.a1 + (target.a1 - p.a1) * dt
                    from.r0 = p.r0 + (target.r0 - p.r0) * ct
                    from.r1 = p.r1 + (target.r1 - p.r1) * ct
                    from.color = p.color + (target.color - p.color) * t
                }
                prev[i].arc = SIMD4<Float>(Float(from.a0), Float(from.a1),
                                           Float(from.r0), Float(from.r1))
                prev[i].color = from.color
                // The quad must cover the whole sweep: union of both sectors'
                // boxes, stored on both buffers (the vertex reads the current).
                let fromBox = SunburstWorld.arcBounds(a0: from.a0, a1: from.a1,
                                                      r0: from.r0, r1: from.r1)
                let union = arcBoundsScratch[i].union(fromBox)
                let bbox = SIMD4<Float>(Float(union.minX - rebaseOrigin.x),
                                        Float(union.minY - rebaseOrigin.y),
                                        Float(union.width), Float(union.height))
                instances[i].bbox = bbox
                prev[i].bbox = bbox
            }
            previous = prev
        }
        recordMorphState(previous: previous)

        renderer.upload(instances: instances, previous: previous)
        if previous != nil { startMorph() } else { morphT = 1 }
    }

    /// Snapshot the pairing dictionaries for the *next* rebuild.
    private func recordMorphState(previous: [ArcInstance]?) {
        var targets: [SunburstWorld.ArcKey: ArcState] = [:]
        targets.reserveCapacity(arcs.count)
        var prevs: [SunburstWorld.ArcKey: ArcState] = [:]
        if previous != nil { prevs.reserveCapacity(arcs.count) }
        for i in arcs.indices {
            let key = SunburstWorld.ArcKey(arcs[i])
            targets[key] = ArcState(a0: arcs[i].a0, a1: arcs[i].a1,
                                    r0: arcs[i].r0, r1: arcs[i].r1,
                                    color: instances[i].color)
            if let previous {
                let p = previous[i]
                prevs[key] = ArcState(a0: Double(p.arc.x), a1: Double(p.arc.y),
                                      r0: CGFloat(p.arc.z), r1: CGFloat(p.arc.w),
                                      color: p.color)
            }
        }
        lastTargets = targets
        lastPrevs = prevs
    }

    /// Rebuild the camera-dependent parts only when the camera leaves the built
    /// margin or its scale drifts past the LOD band. Pure camera frames skip this.
    private func maybeRebuild() {
        guard displayRoot != nil else { return }
        guard builtRect.width > 0 else {
            rebuildArcs(morph: false)
            return
        }
        let drift = cameraScale / builtScale
        let outgrown = !builtRect.contains(camera.rect)
        if outgrown || drift > 1.3 || drift < 0.77 {
            // Morph on zoom-driven rebuilds (LOD ring splits/merges); pan-driven
            // edge fills appear instantly.
            rebuildArcs(morph: drift > 1.3 || drift < 0.77)
        }
    }

    /// Pack `arcs` into GPU instances: bounding quad rebased on the built rect
    /// (floating origin), absolute polar params, packed sRGB colour, dim folded in.
    private func packInstances() {
        let n = arcs.count
        rebaseOrigin = builtRect.origin
        let key = ColorKey(isDark: isDark, version: version)
        if colorKey != key {
            hueIndexCache.removeAll(keepingCapacity: true)
            colorLUT = Array(repeating: nil, count: paletteCount * Self.brightnessBuckets)
            colorKey = key
        }
        if sizeScratch.count < n { sizeScratch = [Int64](repeating: 0, count: n) }
        if arcBoundsScratch.count != n { arcBoundsScratch = [CGRect](repeating: .zero, count: n) }
        var maxSize: Int64 = 1
        for i in 0..<n {
            let s = arcSize(arcs[i])
            sizeScratch[i] = s
            if s > maxSize { maxSize = s }
        }
        let denom = Double(maxSize)
        let highlightName = selectedExt?.displayName
        let hasSearch = highlightName == nil && !searchMatchIDs.isEmpty
        instances.removeAll(keepingCapacity: true)
        instances.reserveCapacity(n)
        for i in 0..<n {
            let arc = arcs[i]
            let box = SunburstWorld.arcBounds(a0: arc.a0, a1: arc.a1, r0: arc.r0, r1: arc.r1)
            arcBoundsScratch[i] = box
            let weight = min(1.0, max(0.0, pow(Double(sizeScratch[i]) / denom, 0.40)))
            var dim: Float = 0
            if let highlightName {
                let arcExt = arc.file?.extName ?? arc.node.dominantExt.displayName
                if arcExt != highlightName { dim = 1 }
            } else if hasSearch, !isUnderMatch(arc.node) {
                dim = 1
            }
            var color = arcColor(for: arc, weight: weight)
            color.w = dim   // `w` carries the dim factor (the shader's alpha is coverage)
            instances.append(ArcInstance(
                bbox: SIMD4<Float>(Float(box.minX - rebaseOrigin.x),
                                   Float(box.minY - rebaseOrigin.y),
                                   Float(box.width), Float(box.height)),
                arc: SIMD4<Float>(Float(arc.a0), Float(arc.a1), Float(arc.r0), Float(arc.r1)),
                color: color))
        }
    }

    /// Highlight/search change: same arcs, new dims — repack and re-upload.
    private func repackInstances() {
        packInstances()
        renderer.upload(instances: instances, previous: nil)
        morphT = 1
        recordMorphState(previous: nil)
    }

    private func arcSize(_ arc: SunburstWorld.Arc) -> Int64 {
        if let file = arc.file { return file.size }
        return arc.isFileBlock ? arc.node.directFilesPhysical : arc.node.sizeOnDisk
    }

    /// File arcs for a block that crossed the file-LOD threshold. `nil` =
    /// listing still loading (a one-shot rebuild retries shortly).
    private func fileArcs(for node: FSNode, controller: ScanController) -> [FileTileInfo]? {
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
            FileTileInfo(name: $0.name, size: $0.physical, extName: OutlineRowView.extDisplay($0.name),
                         divergence: $0.divergence)
        }
    }

    private func scheduleFileRetry() {
        guard !fileRetryScheduled else { return }
        fileRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.fileRetryScheduled = false
            self.rebuildArcs(morph: true)
            self.presentArcs()
        }
    }

    /// sRGB RGBA for an arc, memoised in the same bounded `(hueIndex, bucket)`
    /// LUT as the treemap — identical colour semantics across the two views.
    private func arcColor(for arc: SunburstWorld.Arc, weight: Double) -> SIMD4<Float> {
        let hueIdx: Int
        if let ext = arc.file?.extName {
            hueIdx = Theme.stableIndex(ext, paletteCount)
        } else {
            let oid = ObjectIdentifier(arc.node)
            if let cached = hueIndexCache[oid] {
                hueIdx = cached
            } else {
                hueIdx = Theme.stableIndex(arc.node.dominantExt.displayName, paletteCount)
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
    private func presentArcs() {
        let viewport = camera.rect.offsetBy(dx: -rebaseOrigin.x, dy: -rebaseOrigin.y)
        renderer.draw(into: metalLayer,
                      camera: Camera.ortho(viewport: viewport),
                      pointsPerUnit: cameraScale,
                      center: SIMD2<Float>(Float(SunburstWorld.center.x - rebaseOrigin.x),
                                           Float(SunburstWorld.center.y - rebaseOrigin.y)),
                      morph: morphT,
                      clearColor: backgroundComps,
                      borderColor: borderComps)
    }

    // MARK: Camera navigation (same gestures as the treemap)

    override func scrollWheel(with event: NSEvent) {
        guard displayRoot != nil else { return }
        let isGesture = event.phase != [] || event.momentumPhase != []
        if isGesture {
            let delta = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            camera.pan(byView: delta, viewSize: bounds.size)
            camera.rect = clampedViewport(camera.rect)
            fitMode = camera.rect == fitRect(bounds.size)
        } else {
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
        guard displayRoot != nil else { return }
        zoomCamera(by: 1 + event.magnification, anchor: topLeftPoint(event))
        cameraMoved()
    }

    private func zoomCamera(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        camera.zoom(by: factor, anchorView: anchor, viewSize: bounds.size)
        camera.rect = clampedViewport(camera.rect)
        fitMode = camera.rect == fitRect(bounds.size)
    }

    /// Common postlude of every interactive camera move. (No focus derivation:
    /// the wheel's root is explicit — the camera is free inspection.)
    private func cameraMoved() {
        camAnimating = false
        maybeRebuild()
        presentArcs()
        overlayLayer.setNeedsDisplay()
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
                fitMode = camera.rect == fitRect(bounds.size)
                maybeRebuild()
                overlayLayer.setNeedsDisplay()
            } else {
                active = true
            }
        }
        if morphT < 1 {
            if morphStart < 0 { morphStart = link.timestamp }
            let t = min(1, (link.timestamp - morphStart) / Self.morphDuration)
            morphT = Float(easeInOut(t))
            if t < 1 { active = true } else { overlayLayer.setNeedsDisplay() }
        }
        presentArcs()
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
    }

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
        guard layer === overlayLayer else { return }
        drawOverlay(in: ctx, size: layer.bounds.size)
    }

    /// World point → top-left view coordinates.
    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let (sx, sy) = camera.scale(viewSize: bounds.size)
        return CGPoint(x: (p.x - camera.rect.minX) * sx,
                       y: (p.y - camera.rect.minY) * sy)
    }

    /// Annular-sector path in the context's native bottom-left space. The CG
    /// flip negates world angles (y-up vs y-down), so a world sweep a0→a1 is
    /// drawn −a0→−a1 clockwise.
    private func sectorPath(center: CGPoint, rInner: CGFloat, rOuter: CGFloat,
                            a0: Double, a1: Double, height: CGFloat) -> CGPath {
        let c = CGPoint(x: center.x, y: height - center.y)
        let path = CGMutablePath()
        if a1 - a0 >= 2 * .pi - 1e-9 {
            path.addEllipse(in: CGRect(x: c.x - rOuter, y: c.y - rOuter,
                                       width: rOuter * 2, height: rOuter * 2))
            if rInner > 0 {
                path.addEllipse(in: CGRect(x: c.x - rInner, y: c.y - rInner,
                                           width: rInner * 2, height: rInner * 2))
            }
            return path
        }
        path.move(to: CGPoint(x: c.x + cos(-a0) * rOuter, y: c.y + sin(-a0) * rOuter))
        path.addArc(center: c, radius: rOuter, startAngle: -a0, endAngle: -a1, clockwise: true)
        if rInner > 0 {
            path.addLine(to: CGPoint(x: c.x + cos(-a1) * rInner, y: c.y + sin(-a1) * rInner))
            path.addArc(center: c, radius: rInner, startAngle: -a1, endAngle: -a0, clockwise: false)
        } else {
            path.addLine(to: c)
        }
        path.closeSubpath()
        return path
    }

    private func drawOverlay(in ctx: CGContext, size: CGSize) {
        guard !camAnimating else { return }   // redrawn when the camera lands
        let scale = cameraScale
        let center = viewPoint(SunburstWorld.center)

        // The hole: the display root's own disc — a subtle panel over the map
        // background, the total in the middle (the dotMemory centre).
        let holePts = SunburstWorld.holeRadius * scale
        if morphT >= 1, holePts > 4 {
            let c = CGPoint(x: center.x, y: size.height - center.y)
            let holeRect = CGRect(x: c.x - holePts, y: c.y - holePts,
                                  width: holePts * 2, height: holePts * 2)
            ctx.setFillColor(panelCG)
            ctx.fillEllipse(in: holeRect)
            ctx.setStrokeColor(separatorCG)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: holeRect.insetBy(dx: 0.5, dy: 0.5))
            if holePts > 30, let rootNode = displayRoot {
                drawCenterLabel(in: ctx, center: c, radius: holePts, node: rootNode)
            }
        }

        if let selection, let span = selectionSpan(for: selection) {
            // Spotlight: dim everything outside the selected subtree's sector
            // (its arc through to the rim — the descendants live outward).
            let path = sectorPath(center: center,
                                  rInner: span.rInner * scale,
                                  rOuter: SunburstWorld.discRadius * scale,
                                  a0: span.a0, a1: span.a1, height: size.height)
            ctx.setFillColor(Self.spotlightDimCG)
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)

            ctx.setStrokeColor(Self.blackBorderCG)
            ctx.setLineWidth(4)
            ctx.addPath(path)
            ctx.strokePath()

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: accentShadowCG)
            ctx.setStrokeColor(Self.whiteCG)
            ctx.setLineWidth(2)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        if let hovered {
            let path = sectorPath(center: center,
                                  rInner: hovered.r0 * scale,
                                  rOuter: hovered.r1 * scale,
                                  a0: hovered.a0, a1: hovered.a1, height: size.height)
            ctx.setStrokeColor(Self.hoverCG)
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.strokePath()
        } else if hoveredHole, holePts > 4 {
            let c = CGPoint(x: center.x, y: size.height - center.y)
            ctx.setStrokeColor(Self.hoverCG)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - holePts, y: c.y - holePts,
                                         width: holePts * 2, height: holePts * 2)
                                .insetBy(dx: 0.75, dy: 0.75))
        }
    }

    /// Name + total in the hole, scaled to its projected size (CoreText, drawn
    /// in the context's native y-up space).
    private func drawCenterLabel(in ctx: CGContext, center: CGPoint, radius: CGFloat, node: FSNode) {
        let maxWidth = radius * 1.6
        let sizeFont = NSFont.systemFont(ofSize: min(28, max(11, radius * 0.26)), weight: .semibold)
        let nameFont = NSFont.systemFont(ofSize: min(13, max(9, radius * 0.13)), weight: .medium)
        let sizeLine = truncatedLine(Format.bytes(node.sizeOnDisk),
                                     font: sizeFont, color: textPrimaryCG, width: maxWidth)
        let nameLine = truncatedLine(node.name, font: nameFont, color: textSecondaryCG, width: maxWidth)
        let sizeBounds = CTLineGetBoundsWithOptions(sizeLine, .useOpticalBounds)
        let nameBounds = CTLineGetBoundsWithOptions(nameLine, .useOpticalBounds)
        let gap = radius * 0.10
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: center.x - sizeBounds.width / 2,
                                   y: center.y - sizeBounds.height * 0.36)
        CTLineDraw(sizeLine, ctx)
        ctx.textPosition = CGPoint(x: center.x - nameBounds.width / 2,
                                   y: center.y + gap + sizeBounds.height * 0.55)
        CTLineDraw(nameLine, ctx)
        ctx.restoreGState()
    }

    private func truncatedLine(_ text: String, font: NSFont, color: CGColor, width: CGFloat) -> CTLine {
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        if CTLineGetBoundsWithOptions(line, .useOpticalBounds).width <= width { return line }
        let ellipsis = CTLineCreateWithAttributedString(
            NSAttributedString(string: "…", attributes: [.font: font,
                                                          .foregroundColor: NSColor(cgColor: color) ?? .white]))
        return CTLineCreateTruncatedLine(line, Double(width), .middle, ellipsis) ?? line
    }

    private func isUnderMatch(_ node: FSNode) -> Bool {
        var current: FSNode? = node
        while let n = current {
            if searchMatchIDs.contains(ObjectIdentifier(n)) { return true }
            current = n.parent
        }
        return false
    }

    /// Sector of a selected node: exact span composed down from the display
    /// root (nil when it isn't in the wheel — an ancestor of the hole, another
    /// branch, or the hole itself, which would spotlight everything).
    private func selectionSpan(for node: FSNode) -> SunburstSpan? {
        guard let displayRoot, node !== displayRoot else { return nil }
        return world.worldSpan(of: node, root: displayRoot)
    }

    // MARK: Hit testing & interaction

    private enum Hit {
        case hole
        case arc(SunburstWorld.Arc)
    }

    /// The arc (or the hole) at a mouse location in view coordinates. Rings are
    /// radially disjoint, so the first containing arc is the arc. Arcs below
    /// the sub-pixel cull aren't in the list — can't hover what you can't see.
    private func hitAt(_ point: CGPoint) -> Hit? {
        let pTop = CGPoint(x: point.x, y: bounds.height - point.y)
        let p = camera.viewToWorld(pTop, viewSize: bounds.size)
        let dx = p.x - SunburstWorld.center.x
        let dy = p.y - SunburstWorld.center.y
        let r = sqrt(dx * dx + dy * dy)
        if r <= SunburstWorld.holeRadius { return .hole }
        let theta = atan2(Double(dy), Double(dx))
        for arc in arcs.reversed() where SunburstWorld.contains(arc, r: r, theta: theta) {
            return .arc(arc)
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
        guard !camAnimating else { return }
        let hit = hitAt(convert(event.locationInWindow, from: nil))
        var newArc: SunburstWorld.Arc?
        var newHole = false
        var info: HoverInfo?
        switch hit {
        case .arc(let arc):
            newArc = arc
            info = hoverInfo(for: arc)
        case .hole:
            newHole = true
            if let displayRoot {
                info = HoverInfo(title: displayRoot.name, isDirectory: true,
                                 sizeText: Self.sizeText(onDisk: displayRoot.sizeOnDisk,
                                                         divergence: displayRoot.divergence))
            }
        case nil:
            break
        }
        let arcChanged = newArc?.a0 != hovered?.a0 || newArc?.r0 != hovered?.r0
            || (newArc == nil) != (hovered == nil)
        if arcChanged || newHole != hoveredHole {
            hovered = newArc
            hoveredHole = newHole
            overlayLayer.setNeedsDisplay()
            onHover?(info)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil || hoveredHole else { return }
        hovered = nil
        hoveredHole = false
        overlayLayer.setNeedsDisplay()
        onHover?(nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard !camAnimating else { return }
        let hit = hitAt(convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            guard let controller else { return }
            switch hit {
            case .arc(let arc):
                if let file = arc.file {
                    if let base = controller.path(for: arc.node) {
                        controller.openItem((base == "/" ? "/" : base + "/") + file.name)
                    }
                } else if arc.node.isDirectory, !arc.isFileBlock {
                    controller.zoom(into: arc.node)   // apply() re-roots the wheel
                } else {
                    controller.zoomOut()
                }
            case .hole, nil:
                // The hole is the current root — diving out is the only way down.
                controller.zoomOut()
            }
        } else {
            switch hit {
            case .arc(let arc): controller?.reveal(arc.node)
            case .hole: if let displayRoot { controller?.reveal(displayRoot) }
            case nil: break
            }
        }
    }

    private func hoverInfo(for arc: SunburstWorld.Arc) -> HoverInfo {
        if let file = arc.file {
            return HoverInfo(title: file.name, isDirectory: false,
                             sizeText: Self.sizeText(onDisk: file.size, divergence: file.divergence))
        }
        let node = arc.node
        let divergence = arc.isFileBlock ? nil : node.divergence
        return HoverInfo(title: hoverPath(node), isDirectory: node.isDirectory,
                         sizeText: Self.sizeText(
                            onDisk: arc.isFileBlock ? node.directFilesPhysical : node.sizeOnDisk,
                            divergence: divergence))
    }

    /// "75 MB · 512 GB apparent (sparse)" when the arc hides a divergence;
    /// plain on-disk size otherwise.
    private static func sizeText(onDisk: Int64, divergence: SizeDivergence?) -> String {
        guard let d = divergence else { return Format.bytes(onDisk) }
        return "\(Format.bytes(onDisk)) · \(Format.bytes(d.apparent)) apparent (\(d.label))"
    }

    /// Path of a node relative to the wheel's root — same disambiguation as the
    /// treemap's hover.
    private func hoverPath(_ node: FSNode) -> String {
        guard let displayRoot, node !== displayRoot else { return node.name }
        var parts: [String] = []
        var cur: FSNode? = node
        while let n = cur, n !== displayRoot { parts.append(n.name); cur = n.parent }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !camAnimating, let controller else { return nil }
        let hit = hitAt(convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch hit {
        case .arc(let arc):
            if let file = arc.file {
                MapContextMenu.addFileItems(menu, fileName: file.name, node: arc.node, controller: controller)
            } else {
                MapContextMenu.addDirectoryItems(menu, node: arc.node, controller: controller)
            }
        case .hole:
            if let displayRoot {
                MapContextMenu.addDirectoryItems(menu, node: displayRoot, controller: controller)
            }
        case nil:
            return nil
        }
        return menu.numberOfItems > 0 ? menu : nil
    }
}
