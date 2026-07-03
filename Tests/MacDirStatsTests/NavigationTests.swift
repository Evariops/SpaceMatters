import Testing
import Foundation
@testable import MacDirStats

/// ViewModel-level tests for the navigation & deletion logic changed in Phase 0/2.
/// They drive a real `ScanController` over a real scanned tree — no GUI required —
/// so B1 (use-after-free guard), F2 (selection sync) and A7 (folder count) are
/// verified behaviourally, not just by compiling.
@MainActor
@Suite struct NavigationTests {

    // Builds root/A/B/C + a sibling, each with a small file.
    static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-nav-\(UUID().uuidString)")
        let c = root.appendingPathComponent("A/B/C")
        try fm.createDirectory(at: c, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sibling"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: c.appendingPathComponent("c.bin"))
        try Data(count: 4096).write(to: root.appendingPathComponent("A/a.bin"))
        try Data(count: 4096).write(to: root.appendingPathComponent("sibling/s.bin"))
        return root
    }

    /// Pump the run loop (to fire the controller's refresh Timer) *and* yield to
    /// the concurrency runtime (to let the enqueued MainActor refresh Task run) so
    /// the controller's scalar stats — `phase`, `dirCount` — actually settle.
    static func waitForScan(_ c: ScanController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while c.phase == .scanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    static func child(_ node: FSNode, _ name: String) -> FSNode? {
        node.children.first { $0.name == name }
    }

    @Test func zoomSyncsSelectionAndListRow() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let a = try #require(Self.child(c.root!, "A"))
        c.zoom(into: a)
        // F2: both the treemap selection and the list's selected row follow the zoom.
        #expect(c.zoomRoot === a)
        #expect(c.selection === a)
        #expect(c.selectedRowID == .dir(ObjectIdentifier(a)))
        #expect(c.canZoomOut) // A has a parent (root)

        c.zoomOut()
        #expect(c.zoomRoot === c.root)
        #expect(c.selectedRowID == .dir(ObjectIdentifier(c.root!)))
    }

    @Test func deletingAncestorLiftsNavigationOutOfFreedSubtree() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let a = try #require(Self.child(c.root!, "A"))
        let b = try #require(Self.child(a, "B"))
        let deepC = try #require(Self.child(b, "C"))

        // Zoom deep into C, then delete its ancestor A from under it.
        c.zoom(into: deepC)
        #expect(c.zoomRoot === deepC)
        let dirsBefore = c.dirCount // root, A, B, C, sibling = 5

        let ok = await c.remove(directory: a, permanently: true)
        #expect(ok)

        // B1: zoom/selection must have been lifted onto the surviving parent (root),
        // never left pointing into the freed A/B/C subtree.
        #expect(c.zoomRoot === c.root)
        #expect(c.selection === c.root)
        // Walking the breadcrumb path must not dereference a dangling parent.
        #expect(c.zoomPath.first === c.root)
        // A7: the folder count dropped by the whole deleted subtree (A, B, C).
        #expect(c.dirCount == dirsBefore - 3)
        // A is gone from the tree.
        #expect(Self.child(c.root!, "A") == nil)
    }

    @Test func listSelectionTracksPrimaryAndSet() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let a = try #require(Self.child(c.root!, "A"))
        let sibling = try #require(Self.child(c.root!, "sibling"))

        // Multi-select (as the native table would): two directories, `sibling` primary.
        let ids: Set<ScanController.RowID> = [
            .dir(ObjectIdentifier(a)), .dir(ObjectIdentifier(sibling)),
        ]
        c.setListSelection(ids, primary: .init(
            kind: .directory(sibling), depth: 0, siblingMax: 1,
            isExpandable: false, isExpanded: false, id: .dir(ObjectIdentifier(sibling))))

        // The full set drives mass actions; the primary drives the treemap.
        #expect(c.selectedRowIDs == ids)
        #expect(c.selection === sibling)
        #expect(c.selectedRowID == .dir(ObjectIdentifier(sibling)))

        // A single programmatic select collapses back to one row (no stale multi).
        c.selectDirectory(a)
        #expect(c.selectedRowIDs == [.dir(ObjectIdentifier(a))])
        #expect(c.selection === a)
    }

    @Test func deletingAncestorClearsStaleMultiSelection() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let a = try #require(Self.child(c.root!, "A"))
        let b = try #require(Self.child(a, "B"))
        let sibling = try #require(Self.child(c.root!, "sibling"))

        // Select A, B (inside A) and sibling; then delete A.
        c.setListSelection(
            [.dir(ObjectIdentifier(a)), .dir(ObjectIdentifier(b)), .dir(ObjectIdentifier(sibling))],
            primary: .init(kind: .directory(b), depth: 0, siblingMax: 1,
                           isExpandable: false, isExpanded: false, id: .dir(ObjectIdentifier(b))))
        _ = await c.remove(directory: a, permanently: true)

        // No selected id may point into the freed A/B subtree.
        #expect(!c.selectedRowIDs.contains(.dir(ObjectIdentifier(a))))
        #expect(!c.selectedRowIDs.contains(.dir(ObjectIdentifier(b))))
        // What's left is exactly the surviving primary row.
        #expect(c.selectedRowIDs == c.selectedRowID.map { [$0] } ?? [])
    }

    @Test func deletingFileUpdatesAggregatesAndCount() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let sibling = try #require(Self.child(c.root!, "sibling"))
        let files = c.filesIn(sibling)
        let file = try #require(files.first)
        let rootPhysicalBefore = c.root!.aggPhysical.load(ordering: .relaxed)

        let ok = await c.remove(file: file, parent: sibling, permanently: true)
        #expect(ok)
        // The freed bytes propagated up to the root total.
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) < rootPhysicalBefore)
        #expect(c.filesIn(sibling).isEmpty)
    }
}
