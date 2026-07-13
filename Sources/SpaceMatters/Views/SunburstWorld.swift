import CoreGraphics
import Foundation

// SPEC-13: the persistent sunburst world — the polar sibling of `TreemapWorld`
// (SPEC-10), over the *same* tree. Every node stores its children's angular
// spans *parent-relative, as fractions of the parent span*, decided once and
// revalidated locally (ε-stable). The disc lives in a fixed square world; the
// viewport is only a camera over it. Depth maps to concentric rings whose
// thickness decays geometrically, so an arbitrarily deep tree fits inside a
// finite disc — zooming in (LOD) is what reveals the outer generations.

/// Angular span of a node's sector, absolute (radians, in the world's
/// clockwise-from-noon convention), plus the radius its own ring starts at.
/// The subtree occupies (a0…a1) × (rInner…disc edge).
struct SunburstSpan {
    var a0: Double
    var a1: Double
    var rInner: CGFloat
}

@MainActor
final class SunburstWorld {

    /// A laid-out annular sector in absolute world terms. Angles are radians,
    /// increasing clockwise on screen (the world is y-down), starting at noon.
    struct Arc {
        let a0: Double
        let a1: Double
        let r0: CGFloat
        let r1: CGFloat
        let node: FSNode
        let depth: Int
        let isFileBlock: Bool
        let file: FileTileInfo?
        /// Aggregate remainder closing a ring over sub-pixel siblings (`node`
        /// is then the *parent*) — the polar twin of the treemap's underlay.
        var isTail = false
    }

    /// Identity of an arc across builds — what the morph pairs on (the polar
    /// twin of `TreemapWorld.TileKey`).
    struct ArcKey: Hashable {
        let id: ObjectIdentifier
        let isFileBlock: Bool
        let isTail: Bool
        let fileName: String?

        init(_ arc: Arc) {
            id = ObjectIdentifier(arc.node)
            isFileBlock = arc.isFileBlock
            isTail = arc.isTail
            fileName = arc.file?.name
        }
    }

    struct BuildResult {
        var arcs: [Arc] = []
        var spans: [ObjectIdentifier: SunburstSpan] = [:]
        /// A file listing was requested but hasn't landed yet — the caller
        /// schedules one follow-up rebuild to pick it up.
        var pendingFiles = false
    }

    /// LOD thresholds, in projected screen points (arc length along the ring /
    /// ring thickness). `expandArc > collapseArc` is the hysteresis that keeps
    /// rings from popping at the boundary.
    struct LOD {
        /// Expand a node's children when its own arc is at least this long.
        var expandArc: CGFloat = 14
        var collapseArc: CGFloat = 8
        /// …and only if the children's ring would be at least this thick.
        var minRing: CGFloat = 2.5
        /// A file block subdivides into individual file arcs above this.
        var filesArc: CGFloat = 400
        /// Arcs shorter or thinner than this are culled (sub-pixel).
        var cullSize: CGFloat = 0.5
        /// Safety rail against pathological trees; LOD, not this, is the driver.
        var maxDepth: Int = 64
    }

    // MARK: World geometry (fixed — the disc is aspect-free)

    /// The world is a fixed square: resize never re-bakes anything, the camera
    /// letterboxes (isotropically) instead.
    static let side: CGFloat = 1000
    static let center = CGPoint(x: side / 2, y: side / 2)
    /// Outer limit the rings converge to.
    static let discRadius: CGFloat = 470
    /// The hole: the display root's own disc (total + name live there).
    static let holeRadius: CGFloat = 90
    /// Ring thickness decay: ring d is `k^d` times ring 0. The series converges
    /// to `discRadius`, so every depth exists geometrically — outer generations
    /// are just too thin to draw until the camera closes in.
    static let ringDecay = 0.8
    /// The sweep starts at noon and runs clockwise (dotMemory's convention).
    static let startAngle = -Double.pi / 2

    var worldBounds: CGRect { CGRect(x: 0, y: 0, width: Self.side, height: Self.side) }

    /// Inner radius of ring `d` (children of the display root live in ring 0).
    static func ringInner(_ d: Int) -> CGFloat {
        guard d > 0 else { return holeRadius }
        return holeRadius + (discRadius - holeRadius) * CGFloat(1 - pow(ringDecay, Double(min(d, 512))))
    }

    /// Fraction of the visible rect added on every side when building, so small
    /// pans reuse the built set instead of rebuilding per frame.
    static let buildMargin: CGFloat = 0.25

    // MARK: Per-node entries (the world's persistent structure)

    /// One node's children layout: items + weights (data half), the sibling
    /// order (discrete half — what a re-sort would jump) and parent-relative
    /// span fractions (continuous half).
    private final class Entry {
        var items: [TreemapLayout.Item]
        var weights: [Double]
        /// Children spans as fractions of the parent span, in `items` order.
        var fractions: [(lo: Double, hi: Double)] = []
        /// Version this entry was last validated against (ε check).
        var stamp: UInt64
        /// Weight shares at *decision* time — drift is measured against these,
        /// so many small steps can't silently reorder the wheel.
        var decisionShares: [Double] = []

        init(items: [TreemapLayout.Item], weights: [Double], stamp: UInt64) {
            self.items = items
            self.weights = weights
            self.stamp = stamp
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// LOD hysteresis state: nodes currently expanded.
    private var expanded: Set<ObjectIdentifier> = []
    /// Weight drift (relative to the sibling total) below which an entry keeps
    /// its sibling order and only re-flows the spans — the "local moves" ε.
    static let epsilon = 0.02

    private var version: UInt64 = 0
    private var rootID: ObjectIdentifier?

    // MARK: File-layout LRU (file LOD inside a block arc)

    private struct FileLayout {
        let count: Int64
        let files: [FileTileInfo]
        let fractions: [(lo: Double, hi: Double)]
    }
    private var fileLayouts: [ObjectIdentifier: FileLayout] = [:]
    private var fileLayoutOrder: [ObjectIdentifier] = []
    private static let fileLayoutCap = 64

    // MARK: Synchronisation with the data

    /// Align the world with the current tree state. Entries are keyed by node
    /// and parent-relative, so they survive re-roots (diving is a layout-root
    /// change, not a new world); only a new *scan* root resets everything.
    func sync(root: FSNode, version: UInt64) {
        let rid = ObjectIdentifier(root)
        if rid != rootID {
            entries.removeAll(keepingCapacity: true)
            fileLayouts.removeAll(keepingCapacity: true)
            fileLayoutOrder.removeAll(keepingCapacity: true)
            expanded.removeAll(keepingCapacity: true)
            rootID = rid
        }
        self.version = version
    }

    // MARK: Building (the LOD walk)

    /// Produce the drawable arc set for the given camera, rooted at `root` (the
    /// current zoom root — its children fill the full circle around the hole).
    /// Only arcs intersecting the (margin-inflated) visible rect are walked;
    /// expansion is decided on projected arc length with hysteresis.
    func build(root: FSNode,
               visible: CGRect,
               scale: CGFloat,
               lod: LOD = LOD(),
               needsSpans: Bool,
               files: (FSNode) -> [FileTileInfo]?) -> BuildResult {
        var result = BuildResult()
        result.arcs.reserveCapacity(2048)
        let inflated = visible.insetBy(dx: -visible.width * Self.buildMargin,
                                       dy: -visible.height * Self.buildMargin)
        if needsSpans {
            result.spans[ObjectIdentifier(root)] = SunburstSpan(
                a0: Self.startAngle, a1: Self.startAngle + 2 * .pi, rInner: 0)
        }
        walk(node: root, a0: Self.startAngle, a1: Self.startAngle + 2 * .pi,
             childRing: 0, inflated: inflated, scale: scale, lod: lod,
             needsSpans: needsSpans, files: files, into: &result)
        return result
    }

    /// Decide whether `node`'s children get drawn in ring `childRing`, then
    /// recurse. `a0…a1` is the node's own span (the full circle for the root).
    private func walk(node: FSNode,
                      a0: Double,
                      a1: Double,
                      childRing: Int,
                      inflated: CGRect,
                      scale: CGFloat,
                      lod: LOD,
                      needsSpans: Bool,
                      files: (FSNode) -> [FileTileInfo]?,
                      into result: inout BuildResult) {
        let rIn = Self.ringInner(childRing)
        let rOut = Self.ringInner(childRing + 1)
        // Projected size of what the children would get: their arc runs along
        // the ring's inner edge; their thickness is the ring's.
        let arcLen = (a1 - a0) * Double(rIn) * Double(scale)
        let thickness = (rOut - rIn) * scale

        let id = ObjectIdentifier(node)
        var expand: Bool
        if childRing >= lod.maxDepth || thickness < lod.minRing {
            expand = false
        } else if childRing == 0 {
            expand = true   // the hole always shows its first ring
        } else if arcLen > lod.expandArc {
            expand = true
        } else if arcLen < lod.collapseArc {
            expand = false
        } else {
            expand = expanded.contains(id)
        }
        if expand { expanded.insert(id) } else { expanded.remove(id) }
        guard expand else { return }

        let entry = validatedEntry(for: node)
        guard !entry.items.isEmpty else { return }

        let span = a1 - a0
        for i in entry.items.indices {
            let item = entry.items[i]
            let f = entry.fractions[i]
            let ca0 = a0 + f.lo * span
            let ca1 = a0 + f.hi * span
            // Weights descend, so the first sub-pixel child means everyone
            // after it is sub-pixel too: close the ring with one aggregate
            // remainder in the parent's colour (the polar underlay) instead of
            // leaving a background wedge at the ring's tail.
            if (ca1 - ca0) * Double(rOut) * Double(scale) < lod.cullSize {
                if a1 - ca0 > 0,
                   Self.arcBounds(a0: ca0, a1: a1, r0: rIn, r1: rOut).intersects(inflated) {
                    result.arcs.append(Arc(a0: ca0, a1: a1, r0: rIn, r1: rOut,
                                           node: node, depth: childRing,
                                           isFileBlock: false, file: nil, isTail: true))
                }
                break
            }
            // Reach test on the whole *subtree* sector (through to the disc
            // edge): unlike the treemap, descendants extend radially outward —
            // they can be on screen while the node's own ring is not.
            guard Self.arcBounds(a0: ca0, a1: ca1, r0: rIn, r1: Self.discRadius)
                .intersects(inflated) else { continue }
            let ownVisible = Self.arcBounds(a0: ca0, a1: ca1, r0: rIn, r1: rOut)
                .intersects(inflated)
            if needsSpans, item.file == nil, !item.isFileBlock {
                result.spans[ObjectIdentifier(item.node)] = SunburstSpan(a0: ca0, a1: ca1, rInner: rIn)
            }
            if item.isFileBlock {
                if ownVisible {
                    emitFileBlock(node: node, a0: ca0, a1: ca1, r0: rIn, r1: rOut,
                                  depth: childRing, scale: scale, lod: lod,
                                  files: files, into: &result)
                }
            } else {
                if ownVisible {
                    result.arcs.append(Arc(a0: ca0, a1: ca1, r0: rIn, r1: rOut,
                                           node: item.node, depth: childRing,
                                           isFileBlock: false, file: nil))
                }
                // Descend while the subtree can still paint a pixel somewhere:
                // the angular extent keeps growing with the radius, so measure
                // it at the disc edge, not at this ring.
                if item.node.isDirectory,
                   (ca1 - ca0) * Double(Self.discRadius) * Double(scale) >= lod.cullSize {
                    walk(node: item.node, a0: ca0, a1: ca1, childRing: childRing + 1,
                         inflated: inflated, scale: scale, lod: lod,
                         needsSpans: needsSpans, files: files, into: &result)
                }
            }
        }
    }

    /// The node's own-files block: a single arc below `filesArc`, individual
    /// file arcs above it (file LOD — SPEC-05 generalised, polar edition).
    private func emitFileBlock(node: FSNode,
                               a0: Double, a1: Double,
                               r0: CGFloat, r1: CGFloat,
                               depth: Int,
                               scale: CGFloat,
                               lod: LOD,
                               files: (FSNode) -> [FileTileInfo]?,
                               into result: inout BuildResult) {
        let arcLen = (a1 - a0) * Double(r1) * Double(scale)
        let thickness = (r1 - r0) * scale
        if min(CGFloat(arcLen), thickness) > lod.filesArc,
           let layout = fileLayout(for: node, files: files, pending: &result.pendingFiles) {
            let span = a1 - a0
            for i in layout.files.indices {
                let f = layout.fractions[i]
                let fa0 = a0 + f.lo * span
                let fa1 = a0 + f.hi * span
                // Files are sorted descending too: close the tail of sub-pixel
                // ones with one own-files remainder (see `walk`).
                if (fa1 - fa0) * Double(r1) * Double(scale) < lod.cullSize {
                    if a1 - fa0 > 0 {
                        result.arcs.append(Arc(a0: fa0, a1: a1, r0: r0, r1: r1,
                                               node: node, depth: depth,
                                               isFileBlock: true, file: nil, isTail: true))
                    }
                    break
                }
                result.arcs.append(Arc(a0: fa0, a1: fa1, r0: r0, r1: r1,
                                       node: node, depth: depth,
                                       isFileBlock: false, file: layout.files[i]))
            }
            return
        }
        result.arcs.append(Arc(a0: a0, a1: a1, r0: r0, r1: r1,
                               node: node, depth: depth, isFileBlock: true, file: nil))
    }

    private func fileLayout(for node: FSNode,
                            files: (FSNode) -> [FileTileInfo]?,
                            pending: inout Bool) -> FileLayout? {
        let id = ObjectIdentifier(node)
        let count = node.directFileCount
        if let cached = fileLayouts[id], cached.count == count {
            return cached.files.isEmpty ? nil : cached
        }
        guard let listing = files(node) else {
            pending = true                 // in flight — caller re-builds when it lands
            return nil
        }
        let sorted = listing.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let total = sorted.reduce(0.0) { $0 + Double($1.size) }
        var acc = 0.0
        let fractions: [(lo: Double, hi: Double)] = sorted.map {
            let lo = total > 0 ? acc / total : 0
            acc += Double($0.size)
            return (lo, total > 0 ? acc / total : 0)
        }
        let layout = FileLayout(count: count, files: sorted, fractions: fractions)
        fileLayouts[id] = layout
        fileLayoutOrder.removeAll { $0 == id }
        fileLayoutOrder.append(id)
        if fileLayoutOrder.count > Self.fileLayoutCap {
            fileLayouts.removeValue(forKey: fileLayoutOrder.removeFirst())
        }
        return layout.files.isEmpty ? nil : layout
    }

    // MARK: Entries — lazy build + ε-stable revalidation ("local moves")

    private func validatedEntry(for node: FSNode) -> Entry {
        let id = ObjectIdentifier(node)
        if let entry = entries[id] {
            if entry.stamp != version { revalidate(entry, node: node) }
            return entry
        }
        let built = TreemapLayout.buildItems(node: node, depth: 1, files: nil)
        let entry = Entry(items: built.items, weights: built.weights, stamp: version)
        decide(entry)
        entries[id] = entry
        return entry
    }

    /// The version moved under this entry: rebuild the items and compare against
    /// the *decision-time* shares. Same children and shares within ε → keep the
    /// sibling order and re-flow the span fractions only (exact areas, stable
    /// wheel). Otherwise adopt the fresh descending order — a local move,
    /// animated by the caller's morph.
    private func revalidate(_ entry: Entry, node: FSNode) {
        let built = TreemapLayout.buildItems(node: node, depth: 1, files: nil)
        defer { entry.stamp = version }
        if built.items.count == entry.items.count,
           entry.decisionShares.count == entry.items.count {
            var newWeight: [ArcIdentity: Double] = [:]
            newWeight.reserveCapacity(built.items.count)
            for i in built.items.indices {
                newWeight[ArcIdentity(built.items[i])] = built.weights[i]
            }
            var remapped: [Double] = []
            remapped.reserveCapacity(entry.items.count)
            var sameSet = true
            for item in entry.items {
                guard let w = newWeight[ArcIdentity(item)] else { sameSet = false; break }
                remapped.append(w)
            }
            let newTotal = remapped.reduce(0, +)
            if sameSet, newTotal > 0 {
                var maxDrift = 0.0
                for i in remapped.indices {
                    let drift = abs(remapped[i] / newTotal - entry.decisionShares[i])
                    if drift > maxDrift { maxDrift = drift }
                }
                if maxDrift <= Self.epsilon {
                    // Continuous-only refresh: same order, exact new spans.
                    entry.weights = remapped
                    place(entry)
                    return
                }
            }
        }
        entry.items = built.items
        entry.weights = built.weights
        decide(entry)
    }

    /// A sibling slot's identity, for weight remapping across rebuilds.
    private struct ArcIdentity: Hashable {
        let id: ObjectIdentifier
        let isFileBlock: Bool
        init(_ item: TreemapLayout.Item) {
            id = ObjectIdentifier(item.node)
            isFileBlock = item.isFileBlock
        }
    }

    /// Adopt the current (descending) order as the decision and snapshot the
    /// shares (ε baseline), then flow the spans.
    private func decide(_ entry: Entry) {
        let total = entry.weights.reduce(0, +)
        entry.decisionShares = total > 0 ? entry.weights.map { $0 / total } : []
        place(entry)
    }

    /// The continuous half: children spans as fractions of the parent span,
    /// contiguous, in `items` order.
    private func place(_ entry: Entry) {
        let total = entry.weights.reduce(0, +)
        guard total > 0 else {
            entry.fractions = entry.weights.map { _ in (0, 0) }
            return
        }
        var acc = 0.0
        entry.fractions = entry.weights.map { w in
            let lo = acc / total
            acc += w
            return (lo, acc / total)
        }
    }

    // MARK: World queries

    /// Absolute span of a node under `root`: compose the parent-relative
    /// fractions down the ancestor chain (entries build on demand along the
    /// path). `nil` when the node isn't reachable from the display root — e.g.
    /// an ancestor of it, or a freed subtree mid-refresh.
    func worldSpan(of node: FSNode, root: FSNode) -> SunburstSpan? {
        var chain: [FSNode] = []
        var cur: FSNode? = node
        while let n = cur, n !== root { chain.append(n); cur = n.parent }
        guard cur === root else { return nil }
        var a0 = Self.startAngle
        var a1 = Self.startAngle + 2 * .pi
        var depth = 0
        for child in chain.reversed() {
            let entry = validatedEntry(for: child.parent ?? root)
            guard let i = entry.items.firstIndex(where: { $0.node === child && !$0.isFileBlock && $0.file == nil })
            else { return nil }
            let f = entry.fractions[i]
            let span = a1 - a0
            a1 = a0 + f.hi * span
            a0 = a0 + f.lo * span
            depth += 1
        }
        return SunburstSpan(a0: a0, a1: a1, rInner: depth == 0 ? 0 : Self.ringInner(depth - 1))
    }

    // MARK: Polar helpers (pure geometry, shared with the view)

    /// Normalise any angle into the world's sweep `[startAngle, startAngle+2π)`.
    static func normalized(_ angle: Double) -> Double {
        let twoPi = 2 * Double.pi
        var a = (angle - startAngle).truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return startAngle + a
    }

    /// Whether the polar point `(r, θ)` lies inside the arc.
    static func contains(_ arc: Arc, r: CGFloat, theta: Double) -> Bool {
        guard r >= arc.r0, r <= arc.r1 else { return false }
        let t = normalized(theta)
        return t >= arc.a0 && t <= arc.a1
    }

    /// Tight world-space bounding box of an annular sector (candidates: the four
    /// corners plus every axis crossing inside the sweep, all at the outer radius).
    static func arcBounds(a0: Double, a1: Double, r0: CGFloat, r1: CGFloat) -> CGRect {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        func add(_ a: Double, _ r: CGFloat) {
            let x = cos(a) * Double(r), y = sin(a) * Double(r)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        add(a0, r0); add(a0, r1); add(a1, r0); add(a1, r1)
        if a1 - a0 >= 2 * .pi - 1e-9 {
            add(0, r1); add(.pi / 2, r1); add(.pi, r1); add(3 * .pi / 2, r1)
            // A (near-)full ring around the centre: the hole isn't part of the
            // box shrink — the box is simply the outer square.
        } else {
            let halfPi = Double.pi / 2
            var m = (a0 / halfPi).rounded(.up) * halfPi
            while m <= a1 {
                add(m, r1)
                m += halfPi
            }
        }
        return CGRect(x: Self.center.x + CGFloat(minX),
                      y: Self.center.y + CGFloat(minY),
                      width: CGFloat(maxX - minX),
                      height: CGFloat(maxY - minY))
    }
}
