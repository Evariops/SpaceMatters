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

    /// Size-independent layout structure, memoised per node: each node's children
    /// and file blocks as `Item`s, sorted by weight (descending), with a parallel
    /// `weights` array. These depend only on the tree and metric — never on the
    /// rect — so across a resize they're computed once and reused; only the rect
    /// *placement* (`squarifySorted`) reruns per frame. The model half of the
    /// layout, held by the controller alongside `sortCache`/`fileCache`.
    final class Cache {
        fileprivate var entries: [ObjectIdentifier: (items: [Item], weights: [Double])] = [:]
        private var metric: SizeMetric?
        private var version: UInt64 = .max

        /// Drop the memo when the tree (version) or metric changed; keep it across
        /// pure resizes. Mirrors `ScanController.sortCache`'s invalidation.
        func invalidate(metric: SizeMetric, version: UInt64) {
            if self.metric != metric || self.version != version {
                entries.removeAll(keepingCapacity: true)
                self.metric = metric
                self.version = version
            }
        }
    }

    /// `rootFiles` are the direct files of `root` (the zoom root) — when present,
    /// the root's own-files region is subdivided into individual file tiles
    /// (SPEC-05, B2). Sub-directories always stay aggregated until you zoom in.
    ///
    /// `cache` memoises the size-independent structure (see `Cache`). Across a
    /// resize — same tree, changing rect — the sort and item-building are skipped
    /// and only the rect placement is redone. Pass `nil` for a one-shot layout
    /// (e.g. tests); a persistent cache must be invalidated via `Cache.invalidate`.
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

        // Too small or too deep → draw as a solid leaf tile.
        if rect.width < minSide * 2 || rect.height < minSide * 2 || depth >= maxDepth {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        // Size-independent half: build (and cache) this node's sorted items once.
        let entry: (items: [Item], weights: [Double])
        if let cached = cache.entries[ObjectIdentifier(node)] {
            entry = cached
        } else {
            entry = buildItems(node: node, depth: depth, metric: metric, files: files)
            cache.entries[ObjectIdentifier(node)] = entry
        }

        if entry.items.isEmpty {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        // Size-dependent half: place the (already-sorted) items in this rect.
        let rects = squarifySorted(entry.weights, into: rect)
        for i in entry.items.indices {
            let item = entry.items[i]
            let r = rects[i]
            if r.width <= 0 || r.height <= 0 { continue }
            if item.file != nil {
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: false, file: item.file))
            } else if item.isFileBlock || !item.node.isDirectory {
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: item.isFileBlock))
            } else if r.width < minSide * 2 || r.height < minSide * 2 {
                if needsRegions { result.regions[ObjectIdentifier(item.node)] = r }
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: false))
            } else {
                // Sub-directories: no file refinement (files: nil) — B2.
                layout(node: item.node, rect: r, depth: depth + 1, metric: metric, files: nil,
                       minSide: minSide, maxDepth: maxDepth, cache: cache, needsRegions: needsRegions, into: &result)
            }
        }
    }

    /// Build a node's size-independent items, sorted by weight (descending) so
    /// `squarifySorted` can place them without re-sorting on every resize frame.
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

    /// Place already-sorted (descending) `weights` inside `rect`, returning one rect
    /// per weight in the same order. The squarified packing is identical to
    /// `squarify(_:into:)` — this variant just skips the internal sort because the
    /// caller pre-sorted, which is the whole point on the resize hot path.
    static func squarifySorted(_ weights: [Double], into rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0 else { return result }
        let scale = (Double(rect.width) * Double(rect.height)) / total

        var x = Double(rect.minX)
        var y = Double(rect.minY)
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
            if w >= h {
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

    /// Lay out `weights` (any positive scale) inside `rect`, returning one rect
    /// per input in input order.
    static func squarify(_ weights: [Double], into rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0 else { return result }

        let area = Double(rect.width) * Double(rect.height)
        let scale = area / total
        let order = weights.indices.sorted { weights[$0] > weights[$1] }
        let scaled = order.map { weights[$0] * scale }

        var x = Double(rect.minX)
        var y = Double(rect.minY)
        var w = Double(rect.width)
        var h = Double(rect.height)

        var i = 0
        let n = scaled.count
        while i < n {
            let shorter = min(w, h)
            var rowSum = scaled[i]
            var rowMax = scaled[i]
            var rowMin = scaled[i]
            var k = i + 1
            while k < n {
                let v = scaled[k]
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
            if w >= h {
                var yy = y
                for m in i..<k {
                    let len = thickness == 0 ? 0 : scaled[m] / thickness
                    result[order[m]] = CGRect(x: x, y: yy, width: thickness, height: len)
                    yy += len
                }
                x += thickness
                w -= thickness
            } else {
                var xx = x
                for m in i..<k {
                    let len = thickness == 0 ? 0 : scaled[m] / thickness
                    result[order[m]] = CGRect(x: xx, y: y, width: len, height: thickness)
                    xx += len
                }
                y += thickness
                h -= thickness
            }
            i = k
        }
        return result
    }

    private static func worstRatio(rowSum: Double, maxV: Double, minV: Double, side: Double) -> Double {
        guard rowSum > 0, minV > 0, side > 0 else { return .infinity }
        let s2 = side * side
        let sum2 = rowSum * rowSum
        return max(s2 * maxV / sum2, sum2 / (s2 * minV))
    }
}
