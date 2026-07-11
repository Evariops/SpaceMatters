import Testing
import Foundation
@testable import SpaceMatters

/// Structural-integrity guarantees of the tree lifecycle: in-flight `remove`/
/// `invalidate` must abort cleanly when the tree is replaced or torn down under
/// them (epoch discipline), and a cancelled scan must be *drained* — no worker
/// still mutating the tree — before it reports quiescence.
@MainActor
@Suite struct StructuralIntegrityTests {

    /// Home pressed while a directory removal is suspended off-actor: the
    /// removal must abort before touching the disk or the (gone) tree, and the
    /// controller must land in a clean splash state.
    @Test func goHomeDuringRemoveAbortsWithoutDeleting() async throws {
        let root = try NavigationTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await NavigationTests.waitForScan(c)

        let a = try #require(NavigationTests.child(c.root!, "A"))
        let aPath = root.appendingPathComponent("A").path

        // Start the removal as a MainActor child task: it runs up to its first
        // suspension (the off-actor extension walk), then Home tears the tree
        // down before it can resume.
        let removal = Task { await c.remove(directory: a, permanently: true) }
        await Task.yield()
        c.goHome()
        let ok = await removal.value

        #expect(!ok)
        #expect(FileManager.default.fileExists(atPath: aPath), "the abort must happen before the disk removal")
        #expect(c.root == nil)
        #expect(c.phase == .idle)
    }

    /// Rescan pressed while an `invalidate` re-scans a subtree: the invalidate
    /// must abort without corrupting the fresh scan's totals or File-types.
    @Test func rescanDuringInvalidateLeavesFreshScanIntact() async throws {
        let root = try NavigationTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await NavigationTests.waitForScan(c)
        let cleanPhysical = c.totalPhysical
        let cleanDirs = c.dirCount

        let sub = try #require(NavigationTests.child(c.root!, "A"))
        let invalidation = Task { await c.invalidate(subtree: sub) }
        await Task.yield()
        c.rescan()
        let ok = await invalidation.value
        #expect(!ok)

        await NavigationTests.waitForScan(c)
        #expect(c.phase == .finished)
        // The fresh scan's numbers match the undisturbed first scan exactly —
        // no leftover subtraction from the aborted invalidate.
        #expect(c.totalPhysical == cleanPhysical)
        #expect(c.dirCount == cleanDirs)
    }

    /// While one structural operation is in flight, a second one is refused —
    /// two concurrent tree surgeries would subtract aggregates from each other.
    @Test func concurrentStructuralOpsAreExclusive() async throws {
        let root = try NavigationTests.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = ScanController()
        c.scan(url: root)
        await NavigationTests.waitForScan(c)

        let a = try #require(NavigationTests.child(c.root!, "A"))
        let sibling = try #require(NavigationTests.child(c.root!, "sibling"))

        let first = Task { await c.remove(directory: a, permanently: true) }
        await Task.yield() // let it pass its guards and suspend
        let second = await c.remove(directory: sibling, permanently: true)
        #expect(!second, "second structural op must be refused while the first is in flight")
        let firstOK = await first.value
        #expect(firstOK)
        // The refused sibling is untouched, on disk and in the tree.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sibling").path))
        #expect(NavigationTests.child(c.root!, "sibling") != nil)
    }

    /// A cancelled scan reports drained only once every worker has exited; after
    /// that, the tree must be quiescent (no late aggregate writes).
    @Test func cancelDrainsWorkersBeforeQuiescence() async throws {
        // A wide fixture so several workers are actually busy when cancel lands.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-drain-\(UUID().uuidString)")
        for i in 0..<80 {
            let dir = root.appendingPathComponent("d\(i)/e\(i)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: 4096).write(to: dir.appendingPathComponent("f.bin"))
        }
        defer { try? fm.removeItem(at: root) }

        let node = FSNode(name: "root", parent: nil)
        let scanner = DirectoryScanner(root: node, rootPath: root.path)
        scanner.start()
        scanner.cancel()
        await Task.detached { scanner.waitUntilFinished() }.value

        #expect(scanner.isDrained)
        let settled = node.aggPhysical.load(ordering: .relaxed)
        try await Task.sleep(for: .milliseconds(80))
        #expect(node.aggPhysical.load(ordering: .relaxed) == settled,
                "no worker may keep writing after waitUntilFinished returns")
    }
}
