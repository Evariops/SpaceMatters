import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-10 property tests: the world's geometry is a pure function of the data
/// (the camera never changes it), entries revalidate ε-locally under version
/// bumps, LOD expansion follows projected size with hysteresis, and the camera
/// math holds its invariants (anchor-fixed zoom, view↔world roundtrip).
@MainActor
@Suite struct TreemapWorldTests {

    /// root ── a (600) / b (300) / 100 B of direct files.
    private func makeTree() -> (root: FSNode, a: FSNode, b: FSNode) {
        let root = FSNode(name: "root", parent: nil)
        let a = FSNode(name: "a", parent: root)
        let b = FSNode(name: "b", parent: root)
        a.finishScan(children: [], filesLogical: 600, filesPhysical: 600, fileCount: 6)
        a.aggPhysical.store(600, ordering: .relaxed)
        a.aggLogical.store(600, ordering: .relaxed)
        b.finishScan(children: [], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        b.aggPhysical.store(300, ordering: .relaxed)
        b.aggLogical.store(300, ordering: .relaxed)
        root.finishScan(children: [a, b], filesLogical: 100, filesPhysical: 100, fileCount: 2)
        root.aggPhysical.store(1000, ordering: .relaxed)
        root.aggLogical.store(1000, ordering: .relaxed)
        return (root, a, b)
    }

    private func build(_ world: TreemapWorld, root: FSNode,
                       scale: CGFloat = 1,
                       visible: CGRect? = nil) -> TreemapWorld.BuildResult {
        world.build(root: root, visible: visible ?? world.worldBounds,
                    scale: (sx: scale, sy: scale), needsRegions: true, files: { _ in [] })
    }

    // The world is viewport-independent: two builds with different cameras give
    // identical rects for the tiles they share — the anti-"re-roll" guarantee.
    @Test func cameraNeverMovesTheWorld() {
        let (root, a, _) = makeTree()
        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)

        let full = build(world, root: root, scale: 1)
        let zoomedVisible = CGRect(x: 0, y: 0,
                                   width: world.worldSize.width / 4,
                                   height: world.worldSize.height / 4)
        let zoomed = build(world, root: root, scale: 8, visible: zoomedVisible)

        let rectsFull = Dictionary(uniqueKeysWithValues: full.tiles.map { (TreemapWorld.TileKey($0), $0.rect) })
        for tile in zoomed.tiles {
            if let r = rectsFull[TreemapWorld.TileKey(tile)] {
                #expect(abs(r.minX - tile.rect.minX) < 1e-9)
                #expect(abs(r.width - tile.rect.width) < 1e-9)
            }
        }
        // worldRect(of:) composes to the same geometry the build emits.
        let aRect = world.worldRect(of: a, root: root)
        let aRegion = full.regions[ObjectIdentifier(a)]
        #expect(aRect != nil && aRegion != nil)
        if let aRect, let aRegion {
            #expect(abs(aRect.minX - aRegion.minX) < 1e-9)
            #expect(abs(aRect.width - aRegion.width) < 1e-9)
        }
    }

    // ε-revalidation: a version bump with a small weight drift keeps the discrete
    // structure — tiles stay where they were (bounded slide, no re-roll).
    @Test func smallDriftKeepsTheTiling() {
        let (root, a, _) = makeTree()
        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)
        let before = build(world, root: root, scale: 1)

        // +1 % on `a` — well under ε.
        a.aggPhysical.store(606, ordering: .relaxed)
        root.aggPhysical.store(1006, ordering: .relaxed)
        world.sync(root: root, metric: .physical, version: 2)
        let after = build(world, root: root, scale: 1)

        #expect(after.tiles.count == before.tiles.count)
        let rectsBefore = Dictionary(uniqueKeysWithValues: before.tiles.map { (TreemapWorld.TileKey($0), $0.rect) })
        let slack = world.worldSize.width * 0.05
        for tile in after.tiles {
            guard let r = rectsBefore[TreemapWorld.TileKey(tile)] else { continue }
            #expect(abs(r.minX - tile.rect.minX) < slack)
            #expect(abs(r.minY - tile.rect.minY) < slack)
        }
    }

    // LOD: a scale too small to matter aggregates children; zooming in expands
    // them; sitting back in the hysteresis band keeps the expansion.
    @Test func lodExpansionFollowsProjectedSizeWithHysteresis() {
        let (root, _, _) = makeTree()
        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)

        // Children project far below collapseSide → the root (always expanded)
        // renders its underlay + aggregated children, nothing deeper.
        let coarse = build(world, root: root, scale: 0.005)
        #expect(coarse.tiles.count <= 4)
        #expect(coarse.tiles.allSatisfy { $0.file == nil })
        // The underlay comes first — children paint over it.
        #expect(coarse.tiles.first?.node === root)

        // At scale 1 the children are hundreds of points wide → expanded (here
        // they're leaves, so they stay single tiles — but regions carry them).
        let fine = build(world, root: root, scale: 1)
        #expect(fine.regions[ObjectIdentifier(root)] != nil)

        // Hysteresis: expansion state persists inside the band. Build at an
        // in-between scale twice; the expanded set must not flap.
        let mid1 = build(world, root: root, scale: 0.011)
        let mid2 = build(world, root: root, scale: 0.011)
        #expect(mid1.tiles.count == mid2.tiles.count)
    }

    // File LOD: once a folder's file block projects large enough, its files
    // become individual tiles laid out inside the block.
    @Test func fileBlockRefinesAtFileLODThreshold() {
        let (root, _, _) = makeTree()
        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)

        let files = [
            FileTileInfo(name: "big.bin", size: 70, extName: ".bin"),
            FileTileInfo(name: "small.bin", size: 30, extName: ".bin"),
        ]
        // Only the root's listing resolves; the leaf folders stay aggregate blocks.
        let result = world.build(root: root, visible: world.worldBounds,
                                 scale: (sx: 50, sy: 50), needsRegions: false,
                                 files: { node in node === root ? files : [] })
        let fileTiles = result.tiles.filter { $0.file != nil }
        #expect(fileTiles.count == 2)
        // File tiles partition their block: no overlap.
        if fileTiles.count == 2 {
            #expect(!fileTiles[0].rect.insetBy(dx: 1e-6, dy: 1e-6).intersects(fileTiles[1].rect))
        }

        // A pending listing (nil) keeps the aggregate block and flags the build
        // so the view schedules a follow-up once the listing lands.
        let freshWorld = TreemapWorld()
        freshWorld.sync(root: root, metric: .physical, version: 1)
        let pending = freshWorld.build(root: root, visible: freshWorld.worldBounds,
                                       scale: (sx: 50, sy: 50), needsRegions: false,
                                       files: { _ in nil })
        #expect(pending.pendingFiles)
        #expect(pending.tiles.contains { $0.isFileBlock })
    }

    // Cumulative drift can't produce slivers: many small weight steps (each a
    // few % — under ε per tick against the *last* baseline, which is exactly how
    // stale decisions used to walk away) end up re-decided, keeping the worst
    // tile aspect bounded by the quality guard.
    @Test func cumulativeDriftKeepsTilesSquarish() {
        let root = FSNode(name: "root", parent: nil)
        var kids: [FSNode] = []
        var sizes: [Int64] = [600, 500, 400, 300, 200, 100]
        for (i, s) in sizes.enumerated() {
            let k = FSNode(name: "k\(i)", parent: root)
            k.finishScan(children: [], filesLogical: s, filesPhysical: s, fileCount: 1)
            k.aggPhysical.store(s, ordering: .relaxed)
            kids.append(k)
        }
        root.finishScan(children: kids, filesLogical: 0, filesPhysical: 0, fileCount: 0)
        root.aggPhysical.store(sizes.reduce(0, +), ordering: .relaxed)

        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)
        _ = build(world, root: root, scale: 1)

        // 40 ticks: the biggest child triples gradually (~3 % of total per step,
        // ranking preserved) — the shares walk far from the decided ones.
        for step in 1...40 {
            sizes[0] = 600 + Int64(step) * 30
            kids[0].aggPhysical.store(sizes[0], ordering: .relaxed)
            root.aggPhysical.store(sizes.reduce(0, +), ordering: .relaxed)
            world.sync(root: root, metric: .physical, version: UInt64(1 + step))
            let result = build(world, root: root, scale: 1)
            var worst: CGFloat = 1
            for tile in result.tiles where tile.node !== root {
                guard tile.rect.width > 0, tile.rect.height > 0 else { continue }
                worst = max(worst, max(tile.rect.width / tile.rect.height,
                                       tile.rect.height / tile.rect.width))
            }
            #expect(worst <= TreemapWorld.aspectQualityLimit + 0.5, "worst aspect \(worst) at step \(step)")
        }
    }

    // focusNode derives the deepest folder containing the viewport.
    @Test func focusNodeFollowsTheCamera() {
        let (root, a, _) = makeTree()
        let world = TreemapWorld()
        world.sync(root: root, metric: .physical, version: 1)
        _ = build(world, root: root, scale: 1)

        #expect(world.focusNode(root: root, visible: world.worldBounds) === root)
        if let aRect = world.worldRect(of: a, root: root) {
            let inside = aRect.insetBy(dx: aRect.width * 0.2, dy: aRect.height * 0.2)
            #expect(world.focusNode(root: root, visible: inside) === a)
        }
    }

    // Camera invariants: view↔world roundtrip, and zoom keeps the anchor fixed.
    @Test func cameraMathHoldsItsInvariants() {
        var cam = WorldCamera(rect: CGRect(x: 100, y: 50, width: 800, height: 500))
        let viewSize = CGSize(width: 400, height: 250)

        let p = CGPoint(x: 123, y: 77)
        let w = cam.viewToWorld(p, viewSize: viewSize)
        let back = cam.worldToView(CGRect(origin: w, size: .zero), viewSize: viewSize)
        #expect(abs(back.origin.x - p.x) < 1e-9)
        #expect(abs(back.origin.y - p.y) < 1e-9)

        let anchorWorldBefore = cam.viewToWorld(p, viewSize: viewSize)
        cam.zoom(by: 2.5, anchorView: p, viewSize: viewSize)
        let anchorWorldAfter = cam.viewToWorld(p, viewSize: viewSize)
        #expect(abs(anchorWorldBefore.x - anchorWorldAfter.x) < 1e-9)
        #expect(abs(anchorWorldBefore.y - anchorWorldAfter.y) < 1e-9)
        #expect(abs(cam.rect.width - 800 / 2.5) < 1e-9)
    }

    // Deep-zoom precision: a viewport a millionth of the world still roundtrips
    // exactly in Double (the Float conversion is camera-rebased view-side).
    @Test func deepZoomPrecisionHolds() {
        let world = TreemapWorld()
        let tiny = CGRect(x: world.worldSize.width * 0.7,
                          y: world.worldSize.height * 0.3,
                          width: world.worldSize.width / 1_000_000,
                          height: world.worldSize.height / 1_000_000)
        let cam = WorldCamera(rect: tiny)
        let viewSize = CGSize(width: 1000, height: 700)
        let p = CGPoint(x: 500, y: 350)
        let w = cam.viewToWorld(p, viewSize: viewSize)
        let back = cam.worldToView(CGRect(origin: w, size: .zero), viewSize: viewSize)
        #expect(abs(back.origin.x - p.x) < 1e-6)
        #expect(abs(back.origin.y - p.y) < 1e-6)
    }
}
