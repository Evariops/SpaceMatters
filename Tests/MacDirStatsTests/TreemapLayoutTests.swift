import Testing
import Foundation
@testable import MacDirStats

/// Property tests for the squarified treemap layout (F1): area is conserved,
/// tiles stay inside the target rect, none overlap, and degenerate inputs are
/// handled without trapping.
@Suite struct TreemapLayoutTests {

    @Test func conservesAreaAndStaysInBounds() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let weights = [10.0, 5, 3, 2, 1, 0.5]
        let rects = TreemapLayout.squarify(weights, into: rect)

        #expect(rects.count == weights.count)
        let area = rects.reduce(0.0) { $0 + $1.width * $1.height }
        #expect(abs(area - rect.width * rect.height) < 1.0)

        for r in rects {
            #expect(r.minX >= -0.01 && r.minY >= -0.01)
            #expect(r.maxX <= rect.width + 0.01 && r.maxY <= rect.height + 0.01)
        }
    }

    @Test func tilesDoNotOverlap() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let rects = TreemapLayout.squarify([5, 4, 3, 2, 1], into: rect)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let inter = rects[i].intersection(rects[j])
                #expect(inter.isNull || inter.width < 0.01 || inter.height < 0.01,
                        "tiles \(i) and \(j) overlap")
            }
        }
    }

    @Test func handlesDegenerateInput() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(TreemapLayout.squarify([], into: rect).isEmpty)
        _ = TreemapLayout.squarify([0, 0, 0], into: rect)      // zero weights: must not trap
        _ = TreemapLayout.squarify([1], into: .zero)           // zero rect: must not trap
        _ = TreemapLayout.squarify([-1, 2], into: rect)        // negative weight: must not trap
    }
}
