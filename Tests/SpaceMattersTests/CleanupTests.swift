import Testing
import Foundation
@testable import SpaceMatters

/// Safety invariants of the Low-Hanging Fruits mode. Cleaning deletes real
/// files, so every fence is pinned the same way as `DeletionGuardTests`:
/// contents-only removal, no symlink following, no reach outside the allowed
/// root, and no cleaning while sizes are still being measured.
@MainActor
@Suite struct CleanupTests {

    /// allowedRoot/cache/{a.bin, sub/b.bin} — a fake cache inside a fake home.
    static func makeFixture() throws -> (root: URL, cache: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sm-cleanup-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("cache")
        try fm.createDirectory(at: cache.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: cache.appendingPathComponent("a.bin"))
        try Data(count: 50_000).write(to: cache.appendingPathComponent("sub/b.bin"))
        return (root, cache)
    }

    static func cleanable(_ paths: [String]) -> Cleanable {
        Cleanable(id: "test-cache", name: "Test cache", category: "Test",
                  icon: "shippingbox", note: "fixture", paths: paths)
    }

    static func waitForReady(_ c: CleanupController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while c.state != .ready && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    // MARK: Catalog

    @Test func catalogStaysInsideHome() {
        let home = NSHomeDirectory()
        let items = CleanupEngine.catalog()
        #expect(!items.isEmpty)
        #expect(Set(items.map(\.id)).count == items.count)
        for item in items {
            for path in item.paths {
                #expect(path.hasPrefix(home + "/"), "\(item.id): \(path) escapes home")
                #expect(!path.hasSuffix("/"))
            }
        }
    }

    // MARK: Engine

    @Test func sizingMeasuresFixture() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let measure = CleanupEngine.size(of: Self.cleanable([cache.path]))
        guard case .sized(let bytes) = measure else {
            Issue.record("expected .sized, got \(measure)")
            return
        }
        #expect(bytes >= 150_000) // physical ≥ logical of the two files
    }

    @Test func cleanRemovesContentsButKeepsRoot() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = CleanupEngine.clean(Self.cleanable([cache.path]), allowedRoot: root.path)
        #expect(result.removed == 2) // a.bin + sub (recursively)
        #expect(result.failed == 0 && result.refused == 0)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    /// A symlinked *intermediate* component (`~/.gradle` → an external volume)
    /// passes the textual prefix check but resolves outside the fence — the
    /// clean must refuse it, leaving the relocated cache untouched.
    @Test func cleanRefusesSymlinkedIntermediateComponent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sm-fence-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        let external = base.appendingPathComponent("external/gradle")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: external.appendingPathComponent("caches"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: external.appendingPathComponent("caches/keep.bin"))
        // home/.gradle → external/gradle : the catalog path home/.gradle/caches
        // starts with the fence but really lives outside it.
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle"), withDestinationURL: external)
        defer { try? fm.removeItem(at: base) }

        let target = home.appendingPathComponent(".gradle/caches").path
        let result = CleanupEngine.clean(Self.cleanable([target]), allowedRoot: home.path)

        #expect(result.refused == 1 && result.removed == 0)
        #expect(fm.fileExists(atPath: external.appendingPathComponent("caches/keep.bin").path))
    }

    /// A `..` in the path also defeats the prefix check textually; the resolved
    /// form escapes the fence and must be refused.
    @Test func cleanRefusesDotDotEscape() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sm-dotdot-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: outside.appendingPathComponent("keep.bin"))
        defer { try? fm.removeItem(at: base) }

        let sneaky = home.path + "/../outside"
        let result = CleanupEngine.clean(Self.cleanable([sneaky]), allowedRoot: home.path)

        #expect(result.refused == 1 && result.removed == 0)
        #expect(fm.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    /// A symlink placed inside a cache must be removed as a link — its target,
    /// outside the cache, survives.
    @Test func cleanNeverFollowsSymlinks() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let victimDir = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: victimDir.appendingPathComponent("keep.bin"))
        try FileManager.default.createSymbolicLink(
            at: cache.appendingPathComponent("link"), withDestinationURL: victimDir)

        _ = CleanupEngine.clean(Self.cleanable([cache.path]), allowedRoot: root.path)

        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("link").path))
        #expect(FileManager.default.fileExists(atPath: victimDir.appendingPathComponent("keep.bin").path))
    }

    /// A cache root that is itself a symlink is refused — never resolved and
    /// chased to wherever it points.
    @Test func cleanRefusesSymlinkedRoot() throws {
        let (root, _) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: outside.appendingPathComponent("keep.bin"))
        let link = root.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = CleanupEngine.clean(Self.cleanable([link.path]), allowedRoot: root.path)

        #expect(result.refused == 1 && result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    /// Paths outside the fence are refused wholesale, whatever the catalog says.
    @Test func cleanRefusesOutsideFence() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-fence-\(UUID().uuidString)")
        let result = CleanupEngine.clean(
            Self.cleanable([cache.path]), allowedRoot: elsewhere.path)
        #expect(result.refused == 1 && result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))
    }

    // MARK: Controller

    @Test func controllerSizesSelectsAndCleans() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = CleanupController(catalog: [Self.cleanable([cache.path])], allowedRoot: root.path)
        c.load()
        await Self.waitForReady(c)

        #expect(c.rows.count == 1)
        #expect(c.totalFound >= 150_000)

        c.toggle("test-cache")
        #expect(c.totalSelected == c.totalFound)

        await c.cleanSelected()
        #expect(c.state == .ready)
        #expect(c.lastFreed >= 150_000)
        #expect(c.lastFailures == 0)
        #expect(c.totalFound == 0) // re-measured after cleaning, not assumed
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    /// Mid-sizing, cleaning is refused — sizes aren't trustworthy yet.
    @Test func cleanRefusedWhileSizing() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = CleanupController(catalog: [Self.cleanable([cache.path])], allowedRoot: root.path)
        c.load()
        #expect(c.state == .sizing)

        c.toggle("test-cache")
        await c.cleanSelected() // refused: still sizing
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))

        await Self.waitForReady(c)
        #expect(c.totalFound >= 150_000) // nothing was cleaned
    }

    /// Select-all checkbox cycle: none → all → none, and a partial selection
    /// reads as `.some` and cycles up to `.all`.
    @Test func toggleAllCyclesTriState() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache2 = root.appendingPathComponent("cache2")
        try FileManager.default.createDirectory(at: cache2, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: cache2.appendingPathComponent("c.bin"))

        let second = Cleanable(id: "test-cache-2", name: "Second cache", category: "Test",
                               icon: "shippingbox", note: "fixture", paths: [cache2.path])
        let c = CleanupController(catalog: [Self.cleanable([cache.path]), second],
                                  allowedRoot: root.path)
        c.load()
        await Self.waitForReady(c)

        #expect(c.selectAllState == .none)
        c.toggleAll()
        #expect(c.selectAllState == .all)
        #expect(c.selectedRows.count == 2)

        c.toggle("test-cache-2")
        #expect(c.selectAllState == .some)
        c.toggleAll() // mixed → all
        #expect(c.selectAllState == .all)
        c.toggleAll() // all → none
        #expect(c.selectAllState == .none)
        #expect(c.selectedRows.isEmpty)
    }

    /// Entries whose paths don't exist disappear; existing ones keep only their
    /// existing paths.
    @Test func detectFiltersMissingPaths() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ghost = root.appendingPathComponent("nope").path
        let detected = CleanupEngine.detect([
            Self.cleanable([cache.path, ghost]),
            Cleanable(id: "ghost", name: "Ghost", category: "Test",
                      icon: "shippingbox", note: "", paths: [ghost]),
        ])
        #expect(detected.count == 1)
        #expect(detected[0].paths == [cache.path])
    }
}
