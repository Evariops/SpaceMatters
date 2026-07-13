import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-13 property tests: children partition their parent's span exactly
/// (largest first), the geometry is camera-independent, entries revalidate
/// ε-locally under version bumps, re-rooting composes (`worldSpan`), rings
/// stay inside the disc, LOD expansion follows projected arc length with
/// hysteresis, and the polar helpers (normalise/contains/bounds) hold at the
/// noon seam.
@MainActor
@Suite struct SunburstWorldTests {

    /// root ── a (600: aa 400 / ab 200) / b (300) / 100 B of direct files.
    private func makeTree() -> (root: FSNode, a: FSNode, aa: FSNode, ab: FSNode, b: FSNode) {
        let root = FSNode(name: "root", parent: nil)
        let a = FSNode(name: "a", parent: root)
        let aa = FSNode(name: "aa", parent: a)
        let ab = FSNode(name: "ab", parent: a)
        let b = FSNode(name: "b", parent: root)
        aa.finishScan(children: [], filesLogical: 400, filesPhysical: 400, fileCount: 4)
        aa.aggPhysical.store(400, ordering: .relaxed)
        ab.finishScan(children: [], filesLogical: 200, filesPhysical: 200, fileCount: 2)
        ab.aggPhysical.store(200, ordering: .relaxed)
        a.finishScan(children: [aa, ab], filesLogical: 0, filesPhysical: 0, fileCount: 0)
        a.aggPhysical.store(600, ordering: .relaxed)
        b.finishScan(children: [], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        b.aggPhysical.store(300, ordering: .relaxed)
        root.finishScan(children: [a, b], filesLogical: 100, filesPhysical: 100, fileCount: 2)
        root.aggPhysical.store(1000, ordering: .relaxed)
        return (root, a, aa, ab, b)
    }

    private func build(_ world: SunburstWorld, root: FSNode,
                       scale: CGFloat = 1,
                       lod: SunburstWorld.LOD = SunburstWorld.LOD(),
                       visible: CGRect? = nil) -> SunburstWorld.BuildResult {
        world.build(root: root, visible: visible ?? world.worldBounds,
                    scale: scale, lod: lod, needsSpans: true, files: { _ in [] })
    }

    private let twoPi = 2 * Double.pi

    // Children spans partition the full circle: contiguous, ordered largest
    // first, spans proportional to weights.
    @Test func ringPartitionsTheCircle() {
        let (root, a, _, _, b) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)

        let result = build(world, root: root)
        let ring0 = result.arcs.filter { $0.depth == 0 }
        #expect(ring0.count == 3)   // a, b, own-files block
        #expect(ring0[0].node === a)
        #expect(ring0[1].node === b)
        #expect(ring0[2].isFileBlock)

        // Contiguous from noon, covering exactly the circle.
        #expect(abs(ring0[0].a0 - SunburstWorld.startAngle) < 1e-12)
        for i in 1..<ring0.count {
            #expect(abs(ring0[i].a0 - ring0[i - 1].a1) < 1e-9)
        }
        #expect(abs(ring0.last!.a1 - (SunburstWorld.startAngle + twoPi)) < 1e-9)

        // Angular share = weight share.
        #expect(abs((ring0[0].a1 - ring0[0].a0) / twoPi - 0.6) < 1e-9)
        #expect(abs((ring0[1].a1 - ring0[1].a0) / twoPi - 0.3) < 1e-9)
        #expect(abs((ring0[2].a1 - ring0[2].a0) / twoPi - 0.1) < 1e-9)
    }

    // The camera never moves the world: different viewports/scales agree on
    // every arc they share.
    @Test func cameraNeverMovesTheWorld() {
        let (root, _, _, _, _) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)

        let full = build(world, root: root, scale: 1)
        let corner = CGRect(x: 500, y: 0, width: 250, height: 250)
        let zoomed = build(world, root: root, scale: 8, visible: corner)

        var byKey: [SunburstWorld.ArcKey: SunburstWorld.Arc] = [:]
        for arc in full.arcs { byKey[SunburstWorld.ArcKey(arc)] = arc }
        var shared = 0
        for arc in zoomed.arcs {
            if let ref = byKey[SunburstWorld.ArcKey(arc)] {
                shared += 1
                #expect(abs(ref.a0 - arc.a0) < 1e-12)
                #expect(abs(ref.a1 - arc.a1) < 1e-12)
                #expect(abs(ref.r0 - arc.r0) < 1e-12)
            }
        }
        #expect(shared > 0)
    }

    // ε-stability: a small share drift keeps the sibling order and re-flows the
    // spans exactly; a big drift re-decides (the wheel re-sorts).
    @Test func epsilonKeepsOrderSmallDriftReflows() {
        let (root, a, _, _, b) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)
        _ = build(world, root: root)

        // +4 bytes on b: share drift ≈ 0.1% — order must hold, spans exact.
        b.aggPhysical.store(304, ordering: .relaxed)
        world.sync(root: root, version: 2)
        let small = build(world, root: root)
        let ring0 = small.arcs.filter { $0.depth == 0 }
        #expect(ring0[0].node === a)
        #expect(ring0[1].node === b)
        #expect(abs((ring0[1].a1 - ring0[1].a0) / twoPi - 304.0 / 1004.0) < 1e-9)

        // b grows past a: definitely > ε — the order re-decides, b leads.
        b.aggPhysical.store(700, ordering: .relaxed)
        root.aggPhysical.store(1400, ordering: .relaxed)
        world.sync(root: root, version: 3)
        let big = build(world, root: root)
        let ring0b = big.arcs.filter { $0.depth == 0 }
        #expect(ring0b[0].node === b)
        #expect(ring0b[1].node === a)
    }

    // Re-rooting: the new root's children fill the circle, and worldSpan
    // composes to what the build emits.
    @Test func reRootAndWorldSpanCompose() {
        let (root, a, aa, _, _) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)

        // In the wheel rooted at `root`, aa is a's first child: it starts at
        // noon and covers 2/3 of a's 60% share.
        let spanAA = world.worldSpan(of: aa, root: root)
        #expect(spanAA != nil)
        if let s = spanAA {
            #expect(abs(s.a0 - SunburstWorld.startAngle) < 1e-9)
            #expect(abs((s.a1 - s.a0) / twoPi - 0.4) < 1e-9)
            #expect(abs(s.rInner - SunburstWorld.ringInner(1)) < 1e-9)
        }
        // The build agrees with the composition.
        let result = build(world, root: root)
        if let arcAA = result.arcs.first(where: { $0.node === aa }), let s = spanAA {
            #expect(abs(arcAA.a0 - s.a0) < 1e-9)
            #expect(abs(arcAA.a1 - s.a1) < 1e-9)
        }

        // Re-root at a: its children partition the full circle again.
        let rerooted = build(world, root: a)
        let ring0 = rerooted.arcs.filter { $0.depth == 0 }
        #expect(ring0.count == 2)
        #expect(ring0[0].node === aa)
        #expect(abs((ring0[0].a1 - ring0[0].a0) / twoPi - 2.0 / 3.0) < 1e-9)
        #expect(abs(ring0.last!.a1 - (SunburstWorld.startAngle + twoPi)) < 1e-9)

        // A node outside the wheel (the old root) has no span.
        #expect(world.worldSpan(of: root, root: a) == nil)
    }

    // Rings are monotonic across the whole LOD range and converge inside the
    // disc — depth never escapes. (Past ~depth 150 the geometric term
    // underflows double precision and the radii saturate at the disc edge —
    // fine: LOD culls those rings long before, so only boundedness matters there.)
    @Test func ringsStayInsideTheDisc() {
        var previous = SunburstWorld.ringInner(0)
        #expect(abs(previous - SunburstWorld.holeRadius) < 1e-12)
        for d in 1...200 {
            let r = SunburstWorld.ringInner(d)
            if d <= SunburstWorld.LOD().maxDepth { #expect(r > previous) }
            else { #expect(r >= previous) }
            #expect(r <= SunburstWorld.discRadius + 1e-9)
            previous = r
        }
    }

    // LOD: children appear only when the parent's projected arc is long enough,
    // with hysteresis in the in-between band.
    @Test func lodExpansionFollowsProjectedArcWithHysteresis() {
        let (root, a, _, _, _) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)

        // a's arc at its children's ring is ~625 pt at scale 1. A threshold
        // above that keeps ring 1 collapsed…
        var lod = SunburstWorld.LOD()
        lod.expandArc = 700
        lod.collapseArc = 300
        let collapsed = build(world, root: root, scale: 1, lod: lod)
        #expect(!collapsed.arcs.contains { $0.depth == 1 })
        #expect(collapsed.arcs.contains { $0.node === a })   // a itself is drawn

        // …zooming in (scale 2 → ~1250 pt) expands it…
        let expanded = build(world, root: root, scale: 2, lod: lod)
        #expect(expanded.arcs.contains { $0.depth == 1 })

        // …and back at scale 1 (inside the 300–700 band) hysteresis keeps it open.
        let sticky = build(world, root: root, scale: 1, lod: lod)
        #expect(sticky.arcs.contains { $0.depth == 1 })
    }

    // Sub-pixel siblings: the ring closes with one aggregate remainder arc in
    // the parent's colour — never a background wedge at the tail (the polar
    // twin of the treemap's underlay).
    @Test func subPixelTailClosesTheRing() {
        let root = FSNode(name: "root", parent: nil)
        let big = FSNode(name: "big", parent: root)
        big.finishScan(children: [], filesLogical: 1000, filesPhysical: 1000, fileCount: 1)
        big.aggPhysical.store(1000, ordering: .relaxed)
        var children = [big]
        for i in 0..<60 {
            let tiny = FSNode(name: "t\(i)", parent: root)
            tiny.finishScan(children: [], filesLogical: 1, filesPhysical: 1, fileCount: 1)
            tiny.aggPhysical.store(1, ordering: .relaxed)
            children.append(tiny)
        }
        root.finishScan(children: children, filesLogical: 0, filesPhysical: 0, fileCount: 0)
        root.aggPhysical.store(1060, ordering: .relaxed)

        let world = SunburstWorld()
        world.sync(root: root, version: 1)
        // At scale 0.5 a 1/1060 share is ~0.49 pt at ring 0's outer edge — culled.
        let result = build(world, root: root, scale: 0.5)
        let ring0 = result.arcs.filter { $0.depth == 0 }
        #expect(ring0.count == 2)
        #expect(ring0[0].node === big)
        if let tail = ring0.last, ring0.count == 2 {
            #expect(tail.isTail)
            #expect(tail.node === root)
            #expect(abs(tail.a0 - ring0[0].a1) < 1e-9)
            #expect(abs(tail.a1 - (SunburstWorld.startAngle + twoPi)) < 1e-9)
        }
    }

    // A leaf directory re-rooted: its own files become one full-circle block arc.
    @Test func leafRootIsAFullCircleFileBlock() {
        let (root, _, aa, _, _) = makeTree()
        let world = SunburstWorld()
        world.sync(root: root, version: 1)
        let result = build(world, root: aa)
        #expect(result.arcs.count == 1)
        if let block = result.arcs.first {
            #expect(block.isFileBlock)
            #expect(abs((block.a1 - block.a0) - twoPi) < 1e-9)
            #expect(abs(block.r0 - SunburstWorld.holeRadius) < 1e-9)
        }
    }

    // Polar helpers: containment works across the noon seam, and the bounding
    // box really bounds the sector.
    @Test func polarHelpersHoldAtTheSeam() {
        let start = SunburstWorld.startAngle
        let arc = SunburstWorld.Arc(a0: start + twoPi - 0.2, a1: start + twoPi,
                                    r0: 100, r1: 200,
                                    node: FSNode(name: "x", parent: nil),
                                    depth: 3, isFileBlock: false, file: nil)
        // Just before noon (expressed as a negative offset) is inside…
        #expect(SunburstWorld.contains(arc, r: 150, theta: start - 0.1))
        // …just after noon belongs to the seam's other side.
        #expect(!SunburstWorld.contains(arc, r: 150, theta: start + 0.1))
        // Radial bounds are exclusive of the neighbouring rings.
        #expect(!SunburstWorld.contains(arc, r: 99, theta: start - 0.1))
        #expect(!SunburstWorld.contains(arc, r: 201, theta: start - 0.1))

        // arcBounds contains a dense sample of the sector (any sweep, any ring).
        let sweeps: [(Double, Double)] = [
            (start, start + 0.7),
            (start + 1.2, start + 4.0),
            (start, start + twoPi),
        ]
        for (a0, a1) in sweeps {
            let box = SunburstWorld.arcBounds(a0: a0, a1: a1, r0: 50, r1: 300)
            for i in 0...24 {
                let ang = a0 + (a1 - a0) * Double(i) / 24
                for r in [50.0, 175.0, 300.0] {
                    let p = CGPoint(x: SunburstWorld.center.x + CGFloat(cos(ang) * r),
                                    y: SunburstWorld.center.y + CGFloat(sin(ang) * r))
                    #expect(box.insetBy(dx: -1e-6, dy: -1e-6).contains(p),
                            "(\(ang), \(r)) escaped \(box)")
                }
            }
        }
    }
}
