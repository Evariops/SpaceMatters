import CoreGraphics

/// One of the current zoom root's own files, rendered as its own tile (SPEC-05).
struct FileTileInfo: Equatable {
    let name: String
    let size: Int64      // already resolved to the metric used for layout
    let extName: String  // ".png" etc — colours the tile, matches the legend
}

/// A laid-out rectangle in the treemap.
struct TreemapTile {
    let rect: CGRect
    let node: FSNode
    let depth: Int
    /// True when this tile represents a directory's own files (aggregate block),
    /// rather than a sub-directory.
    let isFileBlock: Bool
    /// Set when this tile is a single file of the zoom root (SPEC-05); `node` is
    /// then the owning directory. `nil` for directory / aggregate-block tiles.
    let file: FileTileInfo?

    init(rect: CGRect, node: FSNode, depth: Int, isFileBlock: Bool, file: FileTileInfo? = nil) {
        self.rect = rect
        self.node = node
        self.depth = depth
        self.isFileBlock = isFileBlock
        self.file = file
    }
}

/// Squarified treemap layout (Bruls, Huizing & van Wijk). Produces tiles whose
/// aspect ratios stay close to 1, recursing into sub-directories until a tile
/// gets too small or we hit the depth cap. Files inside a directory collapse to
/// a single aggregate "files" tile, keeping the tile count bounded.
enum TreemapLayout {
    struct Result {
        var tiles: [TreemapTile] = []
        /// Bounding rectangle each directory occupies (so the list can highlight a
        /// whole subtree, even when it's subdivided into many tiles).
        var regions: [ObjectIdentifier: CGRect] = [:]
    }

    /// The combinatorial layout structure, memoised per node so the map is a
    /// **continuous (monotone) function of size**. Squarify interleaves *discrete*
    /// choices (row grouping, row orientation, which children recurse) with
    /// *continuous* geometry (rects). The discrete choices are what jump under a
    /// resize — a change in one dimension flips `min(w,h)` and thus every
    /// `worstRatio` comparison, reorganising the whole tiling. So we freeze the
    /// discrete choices here (decided once, at a reference rect) and rerun only the
    /// continuous geometry (`placeRows`) per frame: replaying a fixed row/orientation
    /// decomposition on any rect tiles it exactly and continuously. The choices are
    /// rebuilt only when the tree, metric or zoom root changes — never on resize.
    ///
    /// Held by the controller alongside `sortCache`/`fileCache`. At the reference
    /// rect the output is identical to a plain squarify, so the at-rest look is
    /// unchanged; only *how it changes under resize* differs (smoothly, not jumpily).
    final class Cache {
        fileprivate final class Entry {
            let items: [Item]
            let weights: [Double]
            /// Discrete decisions, filled the first time this node is laid out.
            var decided = false
            var breaks: [Int] = []          // exclusive end index of each squarified row
            var orientations: [Bool] = []   // per row: spans the height (a vertical column)
            var recurse: [Bool] = []        // per item: subdivide the subtree (vs a leaf tile)
            init(items: [Item], weights: [Double]) { self.items = items; self.weights = weights }
        }
        fileprivate var entries: [ObjectIdentifier: Entry] = [:]
        private var metric: SizeMetric?
        private var version: UInt64 = .max
        private var rootID: ObjectIdentifier?

        /// Drop the memo when the tree (version), metric or zoom root changed; keep it
        /// across pure resizes. A changed root matters because a node cached as a small
        /// sub-region must re-decide its structure when it becomes the full-rect root.
        func invalidate(metric: SizeMetric, version: UInt64, root: FSNode) {
            let rid = ObjectIdentifier(root)
            if self.metric != metric || self.version != version || self.rootID != rid {
                entries.removeAll(keepingCapacity: true)
                self.metric = metric
                self.version = version
                self.rootID = rid
            }
        }
    }

    /// `rootFiles` are the direct files of `root` (the zoom root) — when present,
    /// the root's own-files region is subdivided into individual file tiles
    /// (SPEC-05, B2). Sub-directories always stay aggregated until you zoom in.
    ///
    /// `cache` memoises the discrete structure (see `Cache`). Across a resize — same
    /// tree, changing rect — the discrete choices are reused and only the continuous
    /// geometry is redone, so the layout flows smoothly. Pass `nil` for a one-shot
    /// layout (e.g. tests); a persistent cache must be invalidated via `Cache.invalidate`.
    /// `needsRegions` builds the per-node bounding-rect map used to outline a
    /// selection. It's only consulted when something is selected, so skip it
    /// otherwise — that's N `ObjectIdentifier`-keyed dict inserts saved on every
    /// resize frame, for nothing on screen.
    static func compute(
        root: FSNode,
        rect: CGRect,
        metric: SizeMetric,
        rootFiles: [FileTileInfo]? = nil,
        cache: Cache? = nil,
        needsRegions: Bool = true,
        minSide: CGFloat = 5,
        maxDepth: Int = 14
    ) -> Result {
        var result = Result()
        result.tiles.reserveCapacity(2048)
        if needsRegions { result.regions.reserveCapacity(2048) }
        layout(node: root, rect: rect, depth: 0, metric: metric, files: rootFiles,
               minSide: minSide, maxDepth: maxDepth, cache: cache ?? Cache(),
               needsRegions: needsRegions, into: &result)
        return result
    }

    fileprivate struct Item {
        let weight: Double
        let node: FSNode
        let isFileBlock: Bool
        let file: FileTileInfo?
    }

    private static func layout(
        node: FSNode,
        rect: CGRect,
        depth: Int,
        metric: SizeMetric,
        files: [FileTileInfo]?,
        minSide: CGFloat,
        maxDepth: Int,
        cache: Cache,
        needsRegions: Bool,
        into result: inout Result
    ) {
        if needsRegions { result.regions[ObjectIdentifier(node)] = rect }

        // Depth cap is structural (size-independent) → monotone-safe to check here.
        if depth >= maxDepth {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        // Size-independent half: build (and cache) this node's sorted items once.
        let entry: Cache.Entry
        if let cached = cache.entries[ObjectIdentifier(node)] {
            entry = cached
        } else {
            let built = buildItems(node: node, depth: depth, metric: metric, files: files)
            entry = Cache.Entry(items: built.items, weights: built.weights)
            cache.entries[ObjectIdentifier(node)] = entry
        }

        if entry.items.isEmpty {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        // Discrete half (decided once, at this reference rect): the squarified row
        // grouping + orientation, and which children recurse (a size threshold on the
        // reference rects). Frozen so a resize can't reorganise the tiling.
        if !entry.decided {
            let decided = decideRows(entry.weights, rect: rect)
            entry.breaks = decided.breaks
            entry.orientations = decided.orientations
            let refRects = placeRows(entry.weights, rect: rect, breaks: entry.breaks, orientations: entry.orientations)
            entry.recurse = entry.items.indices.map { i in
                let item = entry.items[i]
                guard item.file == nil, !item.isFileBlock, item.node.isDirectory else { return false }
                let r = refRects[i]
                return r.width >= minSide * 2 && r.height >= minSide * 2
            }
            entry.decided = true
        }

        // Continuous half: place the fixed rows in the current rect. Reruns per frame.
        let rects = placeRows(entry.weights, rect: rect, breaks: entry.breaks, orientations: entry.orientations)
        for i in entry.items.indices {
            let item = entry.items[i]
            let r = rects[i]
            if r.width <= 0 || r.height <= 0 { continue }
            if item.file != nil {
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: false, file: item.file))
            } else if item.isFileBlock || !item.node.isDirectory {
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: item.isFileBlock))
            } else if entry.recurse[i] {
                // Sub-directories: no file refinement (files: nil) — B2.
                layout(node: item.node, rect: r, depth: depth + 1, metric: metric, files: nil,
                       minSide: minSide, maxDepth: maxDepth, cache: cache, needsRegions: needsRegions, into: &result)
            } else {
                if needsRegions { result.regions[ObjectIdentifier(item.node)] = r }
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: false))
            }
        }
    }

    /// Build a node's size-independent items, sorted by weight (descending) so the
    /// squarify decisions and placement can run without re-sorting on every frame.
    private static func buildItems(
        node: FSNode, depth: Int, metric: SizeMetric, files: [FileTileInfo]?
    ) -> (items: [Item], weights: [Double]) {
        var items: [Item] = []
        for child in node.children {
            let w = Double(child.size(metric))
            if w > 0 { items.append(Item(weight: w, node: child, isFileBlock: false, file: nil)) }
        }
        let directFiles = Double(node.directFilesSize(metric))
        if directFiles > 0 {
            if depth == 0, let files, !files.isEmpty {
                // SPEC-05: individual tiles for the zoom root's own files.
                var listed = 0.0
                for f in files where f.size > 0 {
                    items.append(Item(weight: Double(f.size), node: node, isFileBlock: false, file: f))
                    listed += Double(f.size)
                }
                // Anything the file listing capped off stays a single "other files" block.
                let residual = directFiles - listed
                if residual > 1 { items.append(Item(weight: residual, node: node, isFileBlock: true, file: nil)) }
            } else {
                items.append(Item(weight: directFiles, node: node, isFileBlock: true, file: nil))
            }
        }
        items.sort { $0.weight > $1.weight }
        return (items, items.map(\.weight))
    }

    /// The discrete squarify pass: greedily group already-sorted `weights` into rows
    /// and record each row's break index and orientation (does it span the height —
    /// a vertical column — or the width). No rects; that's `placeRows`. Splitting the
    /// decision from the geometry is what lets the geometry rerun continuously under
    /// resize while the decisions stay put.
    static func decideRows(_ weights: [Double], rect: CGRect) -> (breaks: [Int], orientations: [Bool]) {
        var breaks: [Int] = []
        var orientations: [Bool] = []
        let total = weights.reduce(0, +)
        guard total > 0 else { return (breaks, orientations) }
        let scale = (Double(rect.width) * Double(rect.height)) / total

        var w = Double(rect.width)
        var h = Double(rect.height)
        var i = 0
        let n = weights.count
        while i < n {
            let shorter = min(w, h)
            var rowSum = weights[i] * scale
            var rowMax = rowSum
            var rowMin = rowSum
            var k = i + 1
            while k < n {
                let v = weights[k] * scale
                let withNext = worstRatio(rowSum: rowSum + v, maxV: max(rowMax, v), minV: min(rowMin, v), side: shorter)
                let without = worstRatio(rowSum: rowSum, maxV: rowMax, minV: rowMin, side: shorter)
                if withNext <= without {
                    rowSum += v
                    rowMax = max(rowMax, v)
                    rowMin = min(rowMin, v)
                    k += 1
                } else {
                    break
                }
            }
            let thickness = shorter == 0 ? 0 : rowSum / shorter
            let spansHeight = w >= h
            orientations.append(spansHeight)
            breaks.append(k)
            if spansHeight { w -= thickness } else { h -= thickness }
            i = k
        }
        return (breaks, orientations)
    }

    /// The continuous squarify pass: place a *fixed* row decomposition (`breaks` +
    /// `orientations`) inside `rect`, one rect per weight. Replaying a fixed
    /// decomposition on any rect pieces it out exactly and continuously — the whole
    /// point of the split (`decideRows` freezes the shape, this flows the geometry).
    /// At the rect the decomposition was decided on, the output equals `squarifySorted`.
    static func placeRows(_ weights: [Double], rect: CGRect, breaks: [Int], orientations: [Bool]) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0 else { return result }
        let scale = (Double(rect.width) * Double(rect.height)) / total

        var x = Double(rect.minX)
        var y = Double(rect.minY)
        var w = Double(rect.width)
        var h = Double(rect.height)

        var i = 0
        for row in breaks.indices {
            let k = breaks[row]
            let spansHeight = orientations[row]
            var rowSum = 0.0
            for m in i..<k { rowSum += weights[m] * scale }
            let side = spansHeight ? h : w
            let thickness = side <= 0 ? 0 : rowSum / side
            if spansHeight {
                var yy = y
                for m in i..<k {
                    let len = thickness == 0 ? 0 : (weights[m] * scale) / thickness
                    result[m] = CGRect(x: x, y: yy, width: thickness, height: len)
                    yy += len
                }
                x += thickness
                w -= thickness
            } else {
                var xx = x
                for m in i..<k {
                    let len = thickness == 0 ? 0 : (weights[m] * scale) / thickness
                    result[m] = CGRect(x: xx, y: y, width: len, height: thickness)
                    xx += len
                }
                y += thickness
                h -= thickness
            }
            i = k
        }
        return result
    }

    /// Place already-sorted (descending) `weights` inside `rect` in one shot (decide +
    /// place). Kept for the one-shot path and tests; the cached resize path uses
    /// `decideRows` + `placeRows` instead so the decomposition can be frozen.
    static func squarifySorted(_ weights: [Double], into rect: CGRect) -> [CGRect] {
        let decided = decideRows(weights, rect: rect)
        return placeRows(weights, rect: rect, breaks: decided.breaks, orientations: decided.orientations)
    }

    /// Lay out `weights` (any positive scale) inside `rect`, returning one rect
    /// per input in input order.
    static func squarify(_ weights: [Double], into rect: CGRect) -> [CGRect] {
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        let sorted = order.map { weights[$0] }
        let placed = squarifySorted(sorted, into: rect)
        var result = [CGRect](repeating: .zero, count: weights.count)
        for (slot, original) in order.enumerated() { result[original] = placed[slot] }
        return result
    }

    private static func worstRatio(rowSum: Double, maxV: Double, minV: Double, side: Double) -> Double {
        guard rowSum > 0, minV > 0, side > 0 else { return .infinity }
        let s2 = side * side
        let sum2 = rowSum * rowSum
        return max(s2 * maxV / sum2, sum2 / (s2 * minV))
    }
}
