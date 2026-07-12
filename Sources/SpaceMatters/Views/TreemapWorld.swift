import CoreGraphics
import Foundation

// SPEC-10: the persistent treemap world. The layout is a pure function of the
// tree — every node stores its children's rects *parent-relative, in the unit
// square*, decided once and revalidated locally — and the viewport is only a
// camera over it. Nothing here depends on the window: resize, pan and zoom are
// camera moves; ticks of a live scan revalidate entries lazily (ε-stable local
// moves) instead of re-rolling the whole tiling.

/// The camera: a world-space viewport rect mapped onto the view. Anisotropic by
/// design — at fit the viewport *is* the world rect, so the map fills the pane
/// and any window/world aspect mismatch is a bounded stretch (re-baked away at
/// the end of a resize, see `TreemapNSView`). View coordinates are top-left
/// oriented points (the historical tile convention; CG flips happen at draw).
struct WorldCamera: Equatable {
    var rect: CGRect

    /// Points per world unit on each axis for a given view size.
    func scale(viewSize: CGSize) -> (sx: CGFloat, sy: CGFloat) {
        (viewSize.width / max(rect.width, .leastNormalMagnitude),
         viewSize.height / max(rect.height, .leastNormalMagnitude))
    }

    func viewToWorld(_ p: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(x: rect.minX + p.x / viewSize.width * rect.width,
                y: rect.minY + p.y / viewSize.height * rect.height)
    }

    func worldToView(_ r: CGRect, viewSize: CGSize) -> CGRect {
        let (sx, sy) = scale(viewSize: viewSize)
        return CGRect(x: (r.minX - rect.minX) * sx,
                      y: (r.minY - rect.minY) * sy,
                      width: r.width * sx,
                      height: r.height * sy)
    }

    /// Zoom by `factor` (> 1 zooms in) keeping the world point under `anchorView`
    /// fixed on screen — the Google Maps invariant.
    mutating func zoom(by factor: CGFloat, anchorView: CGPoint, viewSize: CGSize) {
        let anchor = viewToWorld(anchorView, viewSize: viewSize)
        let f = 1 / factor
        rect = CGRect(x: anchor.x - (anchor.x - rect.minX) * f,
                      y: anchor.y - (anchor.y - rect.minY) * f,
                      width: rect.width * f,
                      height: rect.height * f)
    }

    /// Pan by a view-space delta (points).
    mutating func pan(byView delta: CGSize, viewSize: CGSize) {
        let (sx, sy) = scale(viewSize: viewSize)
        rect.origin.x -= delta.width / sx
        rect.origin.y -= delta.height / sy
    }
}

@MainActor
final class TreemapWorld {

    /// A laid-out tile in absolute world coordinates (CGFloat is Double on macOS;
    /// composition happens in full precision — the Float conversion is done
    /// view-side, rebased on the camera).
    struct Tile {
        let rect: CGRect
        let node: FSNode
        let depth: Int
        let isFileBlock: Bool
        let file: FileTileInfo?
    }

    /// Identity of a tile across builds — what the morph pairs on.
    struct TileKey: Hashable {
        let id: ObjectIdentifier
        let isFileBlock: Bool
        let fileName: String?

        init(_ tile: Tile) {
            id = ObjectIdentifier(tile.node)
            isFileBlock = tile.isFileBlock
            fileName = tile.file?.name
        }

        init(id: ObjectIdentifier, isFileBlock: Bool, fileName: String?) {
            self.id = id
            self.isFileBlock = isFileBlock
            self.fileName = fileName
        }
    }

    struct BuildResult {
        var tiles: [Tile] = []
        var regions: [ObjectIdentifier: CGRect] = [:]
        /// A file listing was requested but hasn't landed yet — the caller
        /// schedules one follow-up rebuild to pick it up.
        var pendingFiles = false
    }

    /// LOD thresholds, in projected screen points. `expandSide > collapseSide`
    /// is the hysteresis that keeps tiles from popping at the boundary.
    struct LOD {
        var expandSide: CGFloat = 14
        var collapseSide: CGFloat = 8
        var filesSide: CGFloat = 400
        var cullSide: CGFloat = 0.5
        /// Safety rail against pathological trees; LOD, not this, is the driver.
        var maxDepth: Int = 64
    }

    /// Fraction of the visible rect added on every side when building, so small
    /// pans reuse the built set instead of rebuilding per frame.
    static let buildMargin: CGFloat = 0.25

    // MARK: World state

    /// Abstract world rect: area is normalised (~1e6 units²), aspect follows the
    /// window lazily (re-bake with hysteresis — never mid-drag).
    private(set) var worldSize: CGSize

    private var metric: SizeMetric
    private var version: UInt64
    private var rootID: ObjectIdentifier?

    init(aspect: CGFloat = 1.6, metric: SizeMetric = .physical) {
        self.worldSize = Self.size(forAspect: aspect)
        self.metric = metric
        self.version = 0
    }

    static func size(forAspect aspect: CGFloat) -> CGSize {
        let a = min(max(aspect, 0.2), 5.0)
        return CGSize(width: 1000 * sqrt(a), height: 1000 / sqrt(a))
    }

    var worldBounds: CGRect { CGRect(origin: .zero, size: worldSize) }
    var aspect: CGFloat { worldSize.width / worldSize.height }

    // MARK: Per-node entries (the world's persistent structure)

    /// One node's children layout: items + weights (data half), squarify decisions
    /// (discrete half) and parent-relative unit rects (continuous half).
    private final class Entry {
        var items: [TreemapLayout.Item]
        var weights: [Double]
        var breaks: [Int] = []
        var orientations: [Bool] = []
        /// Children rects relative to the node, in the unit square.
        var unitRects: [CGRect] = []
        /// Version this entry was last validated against (ε check).
        var stamp: UInt64
        /// Snapshot at *decision* time: weight shares and the node's rect aspect.
        /// Drift is measured against these — not the last revalidation — so many
        /// small steps can't walk the tiling arbitrarily far from the shape it
        /// was decided for (the cumulative-drift source of sliver tiles).
        var decisionShares: [Double] = []
        var decisionAspect: CGFloat = 1

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
    /// its discrete decisions and only re-flows geometry — the "local moves" ε.
    static let epsilon = 0.02

    // MARK: File-layout LRU (file LOD, generalising SPEC-05)

    private struct FileLayout {
        let count: Int64
        let metric: SizeMetric
        let files: [FileTileInfo]
        let unitRects: [CGRect]
    }
    private var fileLayouts: [ObjectIdentifier: FileLayout] = [:]
    private var fileLayoutOrder: [ObjectIdentifier] = []
    private static let fileLayoutCap = 64

    // MARK: Synchronisation with the data

    /// Align the world with the current tree state. A metric or root change is a
    /// new world (full reset); a version change only marks entries stale — they
    /// revalidate lazily, locally, on their next visit (ε-stable).
    func sync(root: FSNode, metric: SizeMetric, version: UInt64) {
        let rid = ObjectIdentifier(root)
        if rid != rootID || metric != self.metric {
            entries.removeAll(keepingCapacity: true)
            fileLayouts.removeAll(keepingCapacity: true)
            fileLayoutOrder.removeAll(keepingCapacity: true)
            if rid != rootID { expanded.removeAll(keepingCapacity: true) }
            rootID = rid
            self.metric = metric
        }
        self.version = version
    }

    /// Re-decide the whole world at a new aspect (end of a window resize beyond
    /// the hysteresis band). The only global re-roll allowed — and it's animated.
    func rebake(aspect: CGFloat) {
        worldSize = Self.size(forAspect: aspect)
        entries.removeAll(keepingCapacity: true)
        fileLayouts.removeAll(keepingCapacity: true)
        fileLayoutOrder.removeAll(keepingCapacity: true)
    }

    // MARK: Building (the LOD walk)

    /// Produce the drawable tile set for the given camera. Only nodes intersecting
    /// the (margin-inflated) visible rect are walked; expansion is decided on
    /// projected size with hysteresis; entries build/revalidate lazily on visit.
    func build(root: FSNode,
               visible: CGRect,
               scale: (sx: CGFloat, sy: CGFloat),
               lod: LOD = LOD(),
               needsRegions: Bool,
               files: (FSNode) -> [FileTileInfo]?) -> BuildResult {
        var result = BuildResult()
        result.tiles.reserveCapacity(4096)
        let inflated = visible.insetBy(dx: -visible.width * Self.buildMargin,
                                       dy: -visible.height * Self.buildMargin)
        walk(node: root, rect: worldBounds, depth: 0, inflated: inflated, scale: scale,
             lod: lod, needsRegions: needsRegions, files: files, into: &result)
        return result
    }

    private func walk(node: FSNode,
                      rect: CGRect,
                      depth: Int,
                      inflated: CGRect,
                      scale: (sx: CGFloat, sy: CGFloat),
                      lod: LOD,
                      needsRegions: Bool,
                      files: (FSNode) -> [FileTileInfo]?,
                      into result: inout BuildResult) {
        guard rect.intersects(inflated) else { return }
        let projMin = min(rect.width * scale.sx, rect.height * scale.sy)
        guard projMin >= lod.cullSide else { return }
        if needsRegions { result.regions[ObjectIdentifier(node)] = rect }

        // Hysteresis: expand above expandSide, collapse below collapseSide,
        // keep the previous state in between.
        let id = ObjectIdentifier(node)
        var expand: Bool
        if depth >= lod.maxDepth {
            expand = false
        } else if projMin > lod.expandSide {
            expand = true
        } else if projMin < lod.collapseSide {
            expand = false
        } else {
            expand = expanded.contains(id)
        }
        if depth == 0 { expand = true }   // the root is never an aggregate
        if expand { expanded.insert(id) } else { expanded.remove(id) }

        guard expand else {
            result.tiles.append(Tile(rect: rect, node: node, depth: depth, isFileBlock: false, file: nil))
            return
        }

        let entry = validatedEntry(for: node, rect: rect)
        guard !entry.items.isEmpty else {
            result.tiles.append(Tile(rect: rect, node: node, depth: depth, isFileBlock: false, file: nil))
            return
        }

        // Underlay: the expanded node's own tile, painted *under* its children
        // (painter's order — children come later in the list). Children culled
        // below `cullSide` then show the folder's colour instead of punching a
        // hole to the background — a folder of thousands of sub-pixel children
        // used to read as a black rectangle.
        result.tiles.append(Tile(rect: rect, node: node, depth: depth, isFileBlock: false, file: nil))

        for i in entry.items.indices {
            let item = entry.items[i]
            let u = entry.unitRects[i]
            let r = CGRect(x: rect.minX + u.minX * rect.width,
                           y: rect.minY + u.minY * rect.height,
                           width: u.width * rect.width,
                           height: u.height * rect.height)
            guard r.intersects(inflated),
                  min(r.width * scale.sx, r.height * scale.sy) >= lod.cullSide else { continue }
            if item.isFileBlock {
                emitFileBlock(node: node, rect: r, depth: depth + 1, scale: scale, lod: lod,
                              files: files, into: &result)
            } else {
                walk(node: item.node, rect: r, depth: depth + 1, inflated: inflated, scale: scale,
                     lod: lod, needsRegions: needsRegions, files: files, into: &result)
            }
        }
    }

    /// The node's own-files block: a single tile below `filesSide`, individual
    /// file tiles above it (file LOD — SPEC-05 generalised to any folder big
    /// enough on screen, laid out inside the block so directories stay put).
    private func emitFileBlock(node: FSNode,
                               rect: CGRect,
                               depth: Int,
                               scale: (sx: CGFloat, sy: CGFloat),
                               lod: LOD,
                               files: (FSNode) -> [FileTileInfo]?,
                               into result: inout BuildResult) {
        let projMin = min(rect.width * scale.sx, rect.height * scale.sy)
        if projMin > lod.filesSide, let layout = fileLayout(for: node, files: files, pending: &result.pendingFiles) {
            // Underlay (see `walk`): culled tiny files show the block, not a hole.
            result.tiles.append(Tile(rect: rect, node: node, depth: depth, isFileBlock: true, file: nil))
            for i in layout.files.indices {
                let u = layout.unitRects[i]
                let r = CGRect(x: rect.minX + u.minX * rect.width,
                               y: rect.minY + u.minY * rect.height,
                               width: u.width * rect.width,
                               height: u.height * rect.height)
                guard min(r.width * scale.sx, r.height * scale.sy) >= lod.cullSide else { continue }
                result.tiles.append(Tile(rect: r, node: node, depth: depth, isFileBlock: false, file: layout.files[i]))
            }
            return
        }
        result.tiles.append(Tile(rect: rect, node: node, depth: depth, isFileBlock: true, file: nil))
    }

    private func fileLayout(for node: FSNode,
                            files: (FSNode) -> [FileTileInfo]?,
                            pending: inout Bool) -> FileLayout? {
        let id = ObjectIdentifier(node)
        let count = node.directFileCount
        if let cached = fileLayouts[id], cached.count == count, cached.metric == metric {
            return cached.files.isEmpty ? nil : cached
        }
        guard let listing = files(node) else {
            pending = true                 // in flight — caller re-builds when it lands
            return nil
        }
        let sorted = listing.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        let weights = sorted.map { Double($0.size) }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let layout = FileLayout(count: count, metric: metric, files: sorted,
                                unitRects: TreemapLayout.squarifySorted(weights, into: unit))
        fileLayouts[id] = layout
        fileLayoutOrder.removeAll { $0 == id }
        fileLayoutOrder.append(id)
        if fileLayoutOrder.count > Self.fileLayoutCap {
            fileLayouts.removeValue(forKey: fileLayoutOrder.removeFirst())
        }
        return layout.files.isEmpty ? nil : layout
    }

    // MARK: Entries — lazy build + ε-stable revalidation ("local moves")

    private func validatedEntry(for node: FSNode, rect: CGRect) -> Entry {
        let id = ObjectIdentifier(node)
        if let entry = entries[id] {
            if entry.stamp != version { revalidate(entry, node: node, rect: rect) }
            return entry
        }
        let built = TreemapLayout.buildItems(node: node, depth: 1, metric: metric, files: nil)
        let entry = Entry(items: built.items, weights: built.weights, stamp: version)
        decide(entry, rect: rect)
        entries[id] = entry
        return entry
    }

    /// The version moved under this entry: rebuild its items and compare against
    /// the *decision-time* snapshot. Same children, shares within ε of the decided
    /// shares, node aspect near the decided aspect, and a placement that still
    /// looks good → keep the discrete decisions and re-flow the continuous
    /// geometry only (bit-stable structure, exact areas). Otherwise re-decide
    /// this node alone — a local move, animated by the caller's morph.
    private func revalidate(_ entry: Entry, node: FSNode, rect: CGRect) {
        let built = TreemapLayout.buildItems(node: node, depth: 1, metric: metric, files: nil)
        defer { entry.stamp = version }
        let sameSet = built.items.count == entry.items.count && zip(built.items, entry.items).allSatisfy {
            $0.node === $1.node && $0.isFileBlock == $1.isFileBlock
        }
        if sameSet, entry.decisionShares.count == built.weights.count {
            let newTotal = built.weights.reduce(0, +)
            if newTotal > 0 {
                var maxDrift = 0.0
                for i in built.weights.indices {
                    let drift = abs(built.weights[i] / newTotal - entry.decisionShares[i])
                    if drift > maxDrift { maxDrift = drift }
                }
                let aspect = rect.height > 0 ? rect.width / rect.height : 1
                let aspectDrift = aspect / max(entry.decisionAspect, .leastNormalMagnitude)
                if maxDrift <= Self.epsilon, aspectDrift > 0.8, aspectDrift < 1.25 {
                    // Continuous-only refresh: same rows, exact new areas — kept
                    // only while the result still reads as a squarified map.
                    entry.items = built.items
                    entry.weights = built.weights
                    place(entry, rect: rect)
                    if worstTileAspect(entry, rect: rect) <= Self.aspectQualityLimit { return }
                }
            }
        }
        entry.items = built.items
        entry.weights = built.weights
        decide(entry, rect: rect)
    }

    /// Decide rows at this node's *world aspect* (scale-invariant), derive the
    /// parent-relative unit rects, and snapshot the decision context (ε baseline).
    private func decide(_ entry: Entry, rect: CGRect) {
        let decided = TreemapLayout.decideRows(entry.weights, rect: CGRect(origin: .zero, size: rect.size))
        entry.breaks = decided.breaks
        entry.orientations = decided.orientations
        let total = entry.weights.reduce(0, +)
        entry.decisionShares = total > 0 ? entry.weights.map { $0 / total } : []
        entry.decisionAspect = rect.height > 0 ? rect.width / rect.height : 1
        place(entry, rect: rect)
    }

    /// Sliver guard: worst width/height ratio the unit rects produce at this
    /// node's aspect. Above `aspectQualityLimit` the kept decisions are stale
    /// enough to hurt (long thin tiles — ugly and barely clickable): re-decide.
    static let aspectQualityLimit: CGFloat = 5
    private func worstTileAspect(_ entry: Entry, rect: CGRect) -> CGFloat {
        var worst: CGFloat = 1
        for u in entry.unitRects {
            let w = u.width * rect.width
            let h = u.height * rect.height
            guard w > 0, h > 0 else { continue }
            worst = max(worst, max(w / h, h / w))
        }
        return worst
    }

    private func place(_ entry: Entry, rect: CGRect) {
        let placed = TreemapLayout.placeRows(entry.weights,
                                             rect: CGRect(origin: .zero, size: rect.size),
                                             breaks: entry.breaks,
                                             orientations: entry.orientations)
        let w = max(rect.width, .leastNormalMagnitude)
        let h = max(rect.height, .leastNormalMagnitude)
        entry.unitRects = placed.map {
            CGRect(x: $0.minX / w, y: $0.minY / h, width: $0.width / w, height: $0.height / h)
        }
    }

    // MARK: World queries

    /// Absolute world rect of a node: compose the parent-relative rects down the
    /// ancestor chain (entries build on demand along the path). `nil` when the
    /// node isn't reachable from the root (e.g. freed subtree mid-refresh).
    func worldRect(of node: FSNode, root: FSNode) -> CGRect? {
        var chain: [FSNode] = []
        var cur: FSNode? = node
        while let n = cur, n !== root { chain.append(n); cur = n.parent }
        guard cur === root else { return nil }
        var rect = worldBounds
        for child in chain.reversed() {
            let entry = validatedEntry(for: child.parent ?? root, rect: rect)
            guard let i = entry.items.firstIndex(where: { $0.node === child && !$0.isFileBlock && $0.file == nil })
            else { return nil }
            let u = entry.unitRects[i]
            rect = CGRect(x: rect.minX + u.minX * rect.width,
                          y: rect.minY + u.minY * rect.height,
                          width: u.width * rect.width,
                          height: u.height * rect.height)
        }
        return rect
    }

    /// The deepest directory whose world rect contains the visible rect — what the
    /// breadcrumb/list follow while the camera moves (`zoomRoot` as a derived value).
    func focusNode(root: FSNode, visible: CGRect) -> FSNode {
        var node = root
        var rect = worldBounds
        var depth = 0
        while depth < 64 {
            let entry = validatedEntry(for: node, rect: rect)
            var descended = false
            for i in entry.items.indices {
                let item = entry.items[i]
                guard !item.isFileBlock, item.file == nil, item.node.isDirectory else { continue }
                let u = entry.unitRects[i]
                let r = CGRect(x: rect.minX + u.minX * rect.width,
                               y: rect.minY + u.minY * rect.height,
                               width: u.width * rect.width,
                               height: u.height * rect.height)
                if r.contains(visible) {
                    node = item.node
                    rect = r
                    depth += 1
                    descended = true
                    break
                }
            }
            if !descended { break }
        }
        return node
    }
}
