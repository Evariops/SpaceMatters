import Testing
import Foundation
@testable import SpaceMatters

/// Safety invariants on `ScanController.remove` (J4.4). The UI disables deletion
/// for remote scans and while scanning, but the *model* — the layer that actually
/// calls FileManager — must refuse on its own: a remote node's path is a remote
/// path (FileManager would hit whatever sits at that same path on the local
/// disk), and a mid-scan removal races the scanner's thread pool on the very
/// nodes it is still mutating.
@MainActor
@Suite struct DeletionGuardTests {

    // A real local directory that doubles as the "remote" tree: root/sub/victim.bin.
    static func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-guard-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("sub/victim.bin"))
        return root
    }

    /// Start a command scan whose streamed `find` records mirror the fixture, so
    /// the tree's reconstructed paths land exactly on the local fixture. With
    /// `holdOpen` the process lingers after the records, keeping `phase == .scanning`.
    static func startCommandScan(_ c: ScanController, fixture: URL, isHost: Bool, holdOpen: Bool = false) {
        let p = fixture.path
        let fmt = [
            "d\\t0\\t0\\t\(p)\\000",
            "d\\t0\\t0\\t\(p)/sub\\000",
            "f\\t8\\t4096\\t\(p)/sub/victim.bin\\000",
        ].joined()
        let shell = "printf '\(fmt)'" + (holdOpen ? "; sleep 30" : "")
        let node = FSNode(name: fixture.lastPathComponent, parent: nil)
        let scanner = CommandScanner(
            root: node, rootPath: p,
            executable: "/bin/sh", arguments: ["-c", shell],
            source: .remote("guard-test"))
        c.startBackend(root: node, scanner: scanner, displayPath: p, isHost: isHost,
                       nodePaths: [ObjectIdentifier(node): p])
    }

    /// Wait for a streamed child node to land in the live tree (records are
    /// parsed off-main; pump the run loop like `NavigationTests.waitForScan`).
    static func waitForChild(_ c: ScanController, _ name: String, timeout: TimeInterval = 5) async -> FSNode? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = c.root.flatMap({ NavigationTests.child($0, name) }) { return hit }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        return nil
    }

    /// A remote scan's paths must never be handed to the local FileManager: if
    /// the local disk has the same layout, an unguarded remove deletes a local
    /// directory the user never pointed at.
    @Test func remoteScanRemoveRefusesAndLeavesLocalDiskAlone() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let c = ScanController()
        Self.startCommandScan(c, fixture: fixture, isHost: false)
        await NavigationTests.waitForScan(c)
        #expect(c.phase == .finished)
        #expect(!c.isHostScan)

        let sub = try #require(NavigationTests.child(c.root!, "sub"))
        let ok = await c.remove(directory: sub, permanently: true)
        #expect(!ok)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("sub").path))
        // The tree is untouched too — no aggregates were subtracted.
        #expect(NavigationTests.child(c.root!, "sub") === sub)

        let file = ScanController.FileItem(name: "victim.bin", logical: 4096, physical: 4096)
        let okFile = await c.remove(file: file, parent: sub, permanently: true)
        #expect(!okFile)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("sub/victim.bin").path))
    }

    /// Mid-scan, remove must refuse (J4.4): the backend still owns the nodes,
    /// and deleting would corrupt totals — or race `removeChild` against the
    /// scanner appending to the same array.
    @Test func midScanRemoveRefuses() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let c = ScanController()
        // isHost: true isolates the phase guard from the host-scan guard.
        Self.startCommandScan(c, fixture: fixture, isHost: true, holdOpen: true)
        let sub = try #require(await Self.waitForChild(c, "sub"))
        #expect(c.isScanning)

        let ok = await c.remove(directory: sub, permanently: true)
        #expect(!ok)
        #expect(c.isScanning)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("sub").path))

        let file = ScanController.FileItem(name: "victim.bin", logical: 4096, physical: 4096)
        let okFile = await c.remove(file: file, parent: sub, permanently: true)
        #expect(!okFile)
        #expect(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("sub/victim.bin").path))

        c.cancel() // terminates the lingering `sleep`
    }
}
