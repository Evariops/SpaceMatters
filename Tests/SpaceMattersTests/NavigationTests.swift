import Testing
import Foundation
@testable import SpaceMatters

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

    /// A6: after deleting a subtree, the File-types table must drop the deleted
    /// files' extensions — not keep showing bytes that no longer exist on disk.
    @Test func deletingSubtreeUpdatesFileTypeTable() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-a6-\(UUID().uuidString)")
        // `media/` holds the only .mp4 in the whole tree; `docs/` holds a .txt.
        try fm.createDirectory(at: root.appendingPathComponent("media/clips"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data(count: 8192).write(to: root.appendingPathComponent("media/movie.mp4"))
        try Data(count: 4096).write(to: root.appendingPathComponent("media/clips/trailer.mp4"))
        try Data(count: 2048).write(to: root.appendingPathComponent("docs/readme.txt"))
        defer { try? fm.removeItem(at: root) }

        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        func mp4Bytes() -> Int64 {
            c.extRows.first { $0.name == ".mp4" }?.physical ?? 0
        }
        #expect(mp4Bytes() > 0) // both .mp4 files counted before deletion

        let media = try #require(Self.child(c.root!, "media"))
        let ok = await c.remove(directory: media, permanently: true)
        #expect(ok)

        // The whole .mp4 contribution (both files, incl. the nested one) is gone.
        #expect(c.extRows.first { $0.name == ".mp4" } == nil)
        // The unrelated .txt row is untouched.
        #expect(c.extRows.first { $0.name == ".txt" }?.count == 1)
    }

    /// SPEC-02 `invalidate(subtree:)`: an external disk change (new file + new
    /// subfolder) is reflected after a targeted re-scan — totals, the File-types
    /// table and the folder count all reconcile, and a zoom pointing at a rebuilt
    /// descendant is re-bound by path to the fresh node.
    @Test func invalidateReflectsExternalChanges() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-inv-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("sub/inner")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("sub/a.dat"))
        try Data(count: 4096).write(to: inner.appendingPathComponent("i.dat"))
        defer { try? fm.removeItem(at: root) }

        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let subNode = try #require(Self.child(c.root!, "sub"))
        let innerNode = try #require(Self.child(subNode, "inner"))
        c.zoom(into: innerNode)                     // zoom at a *descendant* of the re-scan target
        let rootPhysBefore = c.root!.aggPhysical.load(ordering: .relaxed)
        let dirsBefore = c.dirCount                 // root + sub + inner = 3
        #expect(c.extRows.first { $0.name == ".xyz" } == nil)

        // External changes below `sub`: a new big file (new extension) + a new folder.
        try Data(count: 65536).write(to: root.appendingPathComponent("sub/new.xyz"))
        try fm.createDirectory(at: root.appendingPathComponent("sub/child"), withIntermediateDirectories: true)
        try Data(count: 8192).write(to: root.appendingPathComponent("sub/child/c.dat"))

        let ok = await c.invalidate(subtree: subNode)
        #expect(ok)

        // Totals grew by the added bytes (≥ 64K); File-types shows .xyz now.
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) > rootPhysBefore + 65536)
        #expect(c.extRows.first { $0.name == ".xyz" }?.count == 1)
        // The new subfolder is counted (folders went 3 → 4).
        #expect(c.dirCount == dirsBefore + 1)
        // Zoom (at the rebuilt descendant) is re-bound by path to the fresh object.
        #expect(c.zoomRoot?.name == "inner")
        #expect(c.zoomRoot !== innerNode)           // fresh object after re-scan
        #expect(c.path(for: c.zoomRoot!) == inner.path)
    }

    /// SPEC-04 end-to-end: after a scan finishes the disk is watched; an external
    /// write marks the touched subtree dirty, and `refreshDirty` re-scans it so the
    /// totals catch up. A small write stays under the banner's size budget, so it
    /// doesn't raise `diskChanged` (issue #14) — the reliable signal here is
    /// `dirtyPaths`. (FSEvents has ~1 s latency, hence the polling.)
    @Test func fsEventsMarkDirtyAndRefreshCatchesUp() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-fse-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("sub/a.dat"))
        defer { try? fm.removeItem(at: root) }

        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)
        #expect(c.phase == .finished)
        #expect(!c.diskChanged)
        #expect(c.dirtyPaths.isEmpty)
        let physBefore = c.root!.aggPhysical.load(ordering: .relaxed)

        // External change: a new file appears under `sub`.
        try Data(count: 200_000).write(to: root.appendingPathComponent("sub/big.new"))

        // Wait (polling, yielding) for FSEvents to mark the subtree dirty.
        let deadline = Date().addingTimeInterval(10)
        while c.dirtyPaths.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(!c.dirtyPaths.isEmpty, "FSEvents should have marked the subtree dirty")

        await c.refreshDirty()
        #expect(!c.diskChanged)                 // badge cleared
        #expect(c.dirtyPaths.isEmpty)
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) > physBefore + 200_000)
    }

    // Zero-size files (in the current metric) are noise for a space tool — macOS
    // marker files like `.localized` must not surface as outline rows, while
    // sibling files with real bytes do.
    @Test func zeroByteFilesAreHiddenFromOutlineRows() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("sibling/.localized"))
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let sibling = try #require(Self.child(c.root!, "sibling"))
        c.expanded.insert(c.root!)
        c.expanded.insert(sibling)
        // File listings load off the main actor: poll until the listing lands.
        var files = c.filesIn(sibling)
        let deadline = Date().addingTimeInterval(5)
        while files.isEmpty && Date() < deadline {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            files = c.filesIn(sibling)
        }
        #expect(files.contains { $0.name == ".localized" })   // listed on disk…

        let rows = c.visibleRows()
        let siblingID = ObjectIdentifier(sibling)
        #expect(rows.contains { $0.id == .file(siblingID, "s.bin") })
        #expect(!rows.contains { $0.id == .file(siblingID, ".localized") }) // …but not shown
    }

    @Test func deletingFileUpdatesAggregatesAndCount() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await Self.waitForScan(c)

        let sibling = try #require(Self.child(c.root!, "sibling"))
        // File listings load off the main actor now: poll until it lands.
        var files = c.filesIn(sibling)
        let deadline = Date().addingTimeInterval(5)
        while files.isEmpty && Date() < deadline {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            files = c.filesIn(sibling)
        }
        let file = try #require(files.first)
        let rootPhysicalBefore = c.root!.aggPhysical.load(ordering: .relaxed)

        let ok = await c.remove(file: file, parent: sibling, permanently: true)
        #expect(ok)
        // The freed bytes propagated up to the root total.
        #expect(c.root!.aggPhysical.load(ordering: .relaxed) < rootPhysicalBefore)
        #expect(c.filesIn(sibling).isEmpty)
    }
}
