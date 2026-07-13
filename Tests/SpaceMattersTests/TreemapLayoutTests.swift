import Testing
import Foundation
@testable import SpaceMatters

/// Property tests for the squarified treemap layout (F1): area is conserved,
/// tiles stay inside the target rect, none overlap, and degenerate inputs are
/// handled without trapping.
@Suite struct TreemapLayoutTests {

    // SPEC-05: the zoom root's own files refine into individual tiles; the
    // overview (no rootFiles) keeps a single aggregate "files" block.
    @Test func zoomRootRefinesIntoFileTiles() {
        let root = FSNode(name: "root", parent: nil)
        let sub = FSNode(name: "sub", parent: root)
        // `sub` carries an aggregate size but no direct files of its own, so it
        // stays a single tile — isolating the zoom-root's file refinement.
        sub.finishScan(children: [], filesLogical: 0, filesPhysical: 0, fileCount: 0)
        sub.aggPhysical.store(500, ordering: .relaxed)
        root.finishScan(children: [sub], filesLogical: 400, filesPhysical: 400, fileCount: 2)
        root.aggPhysical.store(900, ordering: .relaxed) // 400 direct + 500 sub

        let rect = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        // Zoomed into `root`: its two files become their own tiles; `sub` stays a
        // single directory tile (not refined).
        let files = [
            FileTileInfo(name: "a.png", size: 300, extName: ".png"),
            FileTileInfo(name: "b.png", size: 100, extName: ".png"),
        ]
        let refined = TreemapLayout.compute(root: root, rect: rect, rootFiles: files)
        let fileTiles = refined.tiles.filter { $0.file != nil }
        #expect(fileTiles.count == 2)
        #expect(Set(fileTiles.map { $0.file!.name }) == ["a.png", "b.png"])
        #expect(refined.tiles.contains { $0.node === sub && $0.file == nil }) // sub aggregated
        #expect(!refined.tiles.contains { $0.isFileBlock }) // files fully listed → no residual block

        // Overview (no rootFiles): a single aggregate block, no per-file tiles.
        let overview = TreemapLayout.compute(root: root, rect: rect)
        #expect(overview.tiles.allSatisfy { $0.file == nil })
        #expect(overview.tiles.filter { $0.isFileBlock }.count == 1)
    }

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
