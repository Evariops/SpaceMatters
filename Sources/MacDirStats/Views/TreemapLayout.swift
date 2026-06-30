import CoreGraphics

/// A laid-out rectangle in the treemap.
struct TreemapTile {
    let rect: CGRect
    let node: FSNode
    let depth: Int
    /// True when this tile represents a directory's own files (aggregate block),
    /// rather than a sub-directory.
    let isFileBlock: Bool
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

    static func compute(
        root: FSNode,
        rect: CGRect,
        metric: SizeMetric,
        minSide: CGFloat = 5,
        maxDepth: Int = 14
    ) -> Result {
        var result = Result()
        result.tiles.reserveCapacity(2048)
        layout(node: root, rect: rect, depth: 0, metric: metric, minSide: minSide, maxDepth: maxDepth, into: &result)
        return result
    }

    private struct Item {
        let weight: Double
        let node: FSNode
        let isFileBlock: Bool
    }

    private static func layout(
        node: FSNode,
        rect: CGRect,
        depth: Int,
        metric: SizeMetric,
        minSide: CGFloat,
        maxDepth: Int,
        into result: inout Result
    ) {
        result.regions[ObjectIdentifier(node)] = rect

        // Too small or too deep → draw as a solid leaf tile.
        if rect.width < minSide * 2 || rect.height < minSide * 2 || depth >= maxDepth {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        var items: [Item] = []
        for child in node.children {
            let w = Double(child.size(metric))
            if w > 0 { items.append(Item(weight: w, node: child, isFileBlock: false)) }
        }
        let directFiles = Double(node.directFilesSize(metric))
        if directFiles > 0 {
            items.append(Item(weight: directFiles, node: node, isFileBlock: true))
        }

        if items.isEmpty {
            result.tiles.append(TreemapTile(rect: rect, node: node, depth: depth, isFileBlock: false))
            return
        }

        let weights = items.map(\.weight)
        let rects = squarify(weights, into: rect)
        for (i, item) in items.enumerated() {
            let r = rects[i]
            if r.width <= 0 || r.height <= 0 { continue }
            if item.isFileBlock || !item.node.isDirectory {
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: item.isFileBlock))
            } else if r.width < minSide * 2 || r.height < minSide * 2 {
                result.regions[ObjectIdentifier(item.node)] = r
                result.tiles.append(TreemapTile(rect: r, node: item.node, depth: depth + 1, isFileBlock: false))
            } else {
                layout(node: item.node, rect: r, depth: depth + 1, metric: metric, minSide: minSide, maxDepth: maxDepth, into: &result)
            }
        }
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
