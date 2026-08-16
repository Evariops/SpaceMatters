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

    static func waitForCleaning(_ c: CleanupController, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while c.state != .cleaning && Date() < deadline {
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

    /// The Notion target names caches and nothing else. Its siblings inside the
    /// same partition hold state the app cannot refetch — unsynced edits
    /// (IndexedDB), offline attachments (File System), the session (Cookies) —
    /// so widening the paths by one directory turns a regenerable cache into
    /// data loss. Pinned by name: a future edit has to break this to ship.
    @Test func notionTargetTouchesOnlyCaches() throws {
        let home = NSHomeDirectory()
        let notion = try #require(CleanupEngine.catalog().first { $0.id == "notion" })
        let partition = home + "/Library/Application Support/Notion/Partitions/notion/"

        #expect(notion.paths == [partition + "Service Worker/CacheStorage",
                                 partition + "Cache"])
        for forbidden in ["IndexedDB", "Local Storage", "Session Storage", "File System",
                          "Cookies", "Databases", "blob_storage", "Preferences",
                          "Service Worker/Database"] {
            #expect(!notion.paths.contains { $0.hasSuffix("/" + forbidden) },
                    "\(forbidden) is not regenerable — it must never be a cleanup path")
        }
    }

    /// A running Notion blocks its own row: the app holds the cache open, so
    /// deleting underneath it frees nothing until quit and can leave the cache
    /// index describing entries that are gone.
    @Test func notionRowIsBlockedWhileTheAppRuns() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let notion = Cleanable(id: "notion", name: "Notion cache", category: "Apps",
                               icon: "note.text", note: "fixture", paths: [cache.path])
        let c = CleanupController(
            catalog: [notion], allowedRoot: root.path,
            blockedReason: { item, _ in
                item.id == "notion" ? "Notion is running — quit it first" : nil
            },
            journal: { _ in })
        c.load()
        await Self.waitForReady(c)

        #expect(c.rows.first?.size == .blocked("Notion is running — quit it first"))
        c.toggleAll() // select-all must not sweep a blocked app row up
        #expect(c.selectedRows.isEmpty)

        await c.cleanSelected()
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))
    }

    /// The reason `go-mod` is native-required, pinned as an executable fact
    /// rather than a comment: Go marks each extracted module tree read-only
    /// (0555, deepest first), and unlinking an entry needs write permission on
    /// its parent *directory*. So the file engine reports failures and frees
    /// nothing — exactly what `rm -rf $GOPATH/pkg/mod` does. If this ever
    /// starts passing, the toolchain requirement can be reconsidered.
    @Test func fileRemovalCannotEmptyAReadOnlyGoModuleTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sm-gomod-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("pkg/mod")
        let module = cache.appendingPathComponent("example.com/lib@v1.0.0")
        try fm.createDirectory(at: module.appendingPathComponent("internal"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: module.appendingPathComponent("internal/lib.go"))
        // Deepest first, as `go mod download` does.
        for dir in [module.appendingPathComponent("internal"), module,
                    cache.appendingPathComponent("example.com")] {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        }
        defer {
            for dir in [cache.appendingPathComponent("example.com"), module,
                        module.appendingPathComponent("internal")] {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
            try? fm.removeItem(at: root)
        }

        let result = CleanupEngine.clean(Self.cleanable([cache.path]), allowedRoot: root.path)

        #expect(result.failed == 1 && result.removed == 0)
        #expect(fm.fileExists(atPath: module.appendingPathComponent("internal/lib.go").path))
    }

    /// The module cache target points at GOPATH's documented default and is
    /// the one entry that blocks without its toolchain.
    @Test func goModCacheTargetsTheDefaultGopath() throws {
        let goMod = try #require(CleanupEngine.catalog(home: "/Users/x").first { $0.id == "go-mod" })
        #expect(goMod.paths == ["/Users/x/go/pkg/mod"])
        #expect(NativeCleaner.missingRequirement(
            for: goMod.id, home: "/Users/x", isExecutable: { _ in false }) != nil)
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

    /// A multi-path target (NuGet, Notion) becomes several scanner seeds whose
    /// sizes reach the total up the parent chain, not through the child list —
    /// so the total must be the sum of every path, and a missing one must not
    /// void the others.
    @Test func sizingAggregatesEveryPathOfATarget() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let second = root.appendingPathComponent("cache2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: second.appendingPathComponent("c.bin"))

        let both = CleanupEngine.size(of: Self.cleanable(
            [cache.path, second.path, root.appendingPathComponent("absent").path]))
        let first = CleanupEngine.size(of: Self.cleanable([cache.path]))
        let other = CleanupEngine.size(of: Self.cleanable([second.path]))

        guard case .sized(let bothBytes) = both, case .sized(let firstBytes) = first,
              case .sized(let otherBytes) = other else {
            Issue.record("expected .sized for all three, got \(both) / \(first) / \(other)")
            return
        }
        #expect(bothBytes == firstBytes + otherBytes)
        #expect(otherBytes >= 200_000)
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
        let c = CleanupController(catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
                                  journal: { _ in }) // fixtures must never write the user's journal
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
        let c = CleanupController(catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
                                  journal: { _ in }) // fixtures must never write the user's journal
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
                                  allowedRoot: root.path, journal: { _ in })
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

    /// A confirmed batch survives leaving the mode: every deletion runs to
    /// completion, only the UI writes are dropped, and the controller lands
    /// back on a terminal state instead of a forever-`.cleaning` brick.
    @Test func stopMidCleanCompletesBatchAndRestoresState() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache2 = root.appendingPathComponent("cache2")
        try FileManager.default.createDirectory(at: cache2, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: cache2.appendingPathComponent("c.bin"))
        let second = Cleanable(id: "test-cache-2", name: "Second cache", category: "Test",
                               icon: "shippingbox", note: "fixture", paths: [cache2.path])
        let c = CleanupController(catalog: [Self.cleanable([cache.path]), second],
                                  allowedRoot: root.path, journal: { _ in })
        c.load()
        await Self.waitForReady(c)
        c.toggleAll()

        let batch = Task { await c.cleanSelected() }
        await Self.waitForCleaning(c)
        c.stop() // user leaves the mode right after confirming
        await batch.value

        #expect(c.state == .ready)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache2.path).isEmpty)
        #expect(c.lastFreed == 0) // results are never stamped on a session that left
    }

    /// A reload asked for mid-clean (mode re-entered) is deferred, not dropped:
    /// the batch is left untouched and fresh rows appear once it lands.
    @Test func reloadDuringCleanIsDeferredUntilBatchEnds() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = CleanupController(catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
                                  journal: { _ in }) // fixtures must never write the user's journal
        c.load()
        await Self.waitForReady(c)
        c.toggle("test-cache")

        let batch = Task { await c.cleanSelected() }
        await Self.waitForCleaning(c)
        c.load() // re-entering the mode mid-batch
        #expect(c.state == .cleaning) // rows/state untouched under the operation

        await batch.value
        await Self.waitForReady(c)
        // The deferred reload ran as a *fresh* load: the cache the batch just
        // emptied re-measures at 0 B and is dropped by the empty-row rule.
        #expect(c.rows.isEmpty)
        #expect(c.totalFound == 0)
    }

    /// When a native cleaner is available the vendor's tool runs and the file
    /// engine never touches the cache; a non-zero exit is surfaced, not
    /// silently retried as file removal (the failure may be the vendor's lock
    /// doing its job).
    @Test func nativeCleanerReplacesFileRemovalAndSurfacesFailure() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = NativeCleaner(binary: "/usr/bin/false", arguments: [],
                                 environment: [:], timeout: 5, label: "fake prune")
        let calls = CallCounter()
        let c = CleanupController(
            catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
            nativeLookup: { id, _ in id == "test-cache" ? fake : nil },
            nativeRunner: { _ in
                await calls.bump()
                return ProcessResult(stdout: Data(), stderr: Data("store is busy".utf8),
                                     exitCode: 1, timedOut: false)
            },
            journal: { _ in })
        c.load()
        await Self.waitForReady(c)
        #expect(c.rows.first?.nativeLabel == "fake prune")

        c.toggle("test-cache")
        await c.cleanSelected()

        #expect(await calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))
        #expect(c.lastNativeIssues == ["Test cache — fake prune: store is busy"])
        #expect(c.state == .ready)
    }

    /// The Trash is user data, not a cache: the select-all header ignores it in
    /// both directions — it is only ever selected row by row. The rule is the
    /// target's `regenerable` flag, not its id, so orphaned editor state gets
    /// the same protection without a second special case.
    @Test func selectAllNeverTouchesTheTrash() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let trashDir = root.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: trashDir.appendingPathComponent("t.bin"))
        let trash = Cleanable(id: "trash", name: "Trash", category: "System",
                              icon: "trash.fill", note: "fixture", paths: [trashDir.path],
                              regenerable: false)
        let c = CleanupController(catalog: [Self.cleanable([cache.path]), trash],
                                  allowedRoot: root.path, journal: { _ in })
        c.load()
        await Self.waitForReady(c)

        c.toggleAll()
        #expect(c.selectAllState == .all) // all *cache* rows selected…
        #expect(c.selectedRows.map(\.id) == ["test-cache"]) // …Trash left alone

        c.toggle("trash") // explicit per-row opt-in still works
        #expect(c.selectedRows.count == 2)
        c.toggleAll() // all → none clears caches, not the hand-picked Trash
        #expect(c.selectedRows.map(\.id) == ["trash"])
    }

    /// A blocked target (uv in link-mode=symlink) is shown but never sized,
    /// never selectable — and a stale selection doesn't survive into it.
    @Test func blockedRowIsVisibleButInert() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let c = CleanupController(
            catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
            blockedReason: { item, _ in item.id == "test-cache" ? "would break venvs" : nil },
            journal: { _ in })
        c.load()
        await Self.waitForReady(c)

        #expect(c.rows.first?.size == .blocked("would break venvs"))
        c.toggle("test-cache") // the model refuses, not just the disabled checkbox
        c.toggleAll()
        #expect(c.selectedRows.isEmpty)
        #expect(c.state == .ready) // an all-blocked catalog still settles

        await c.cleanSelected()
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))
    }

    /// The uv guard reads the environment and uv's user-level config.
    @Test func uvSymlinkModeDetection() throws {
        #expect(CleanupEngine.uvSymlinkMode(home: "/nonexistent", environment: [:]) == false)
        #expect(CleanupEngine.uvSymlinkMode(home: "/nonexistent",
                                            environment: ["UV_LINK_MODE": "symlink"]))
        #expect(CleanupEngine.uvSymlinkMode(home: "/nonexistent",
                                            environment: ["UV_LINK_MODE": "hardlink"]) == false)

        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("sm-uv-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let configDir = home.appendingPathComponent(".config/uv")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try #"link-mode = "symlink""#.write(
            to: configDir.appendingPathComponent("uv.toml"), atomically: true, encoding: .utf8)
        #expect(CleanupEngine.uvSymlinkMode(home: home.path, environment: [:]))

        try #"# link-mode = "symlink""#.write(
            to: configDir.appendingPathComponent("uv.toml"), atomically: true, encoding: .utf8)
        #expect(CleanupEngine.uvSymlinkMode(home: home.path, environment: [:]) == false)
    }

    /// Every cleaned target leaves a journal entry: engine, sizes before and
    /// after, and per-child outcome — the forensic trail for field reports.
    @Test func cleanJournalsEachTarget() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = JournalBox()
        let c = CleanupController(catalog: [Self.cleanable([cache.path])],
                                  allowedRoot: root.path,
                                  journal: { box.entries.append($0) })
        c.load()
        await Self.waitForReady(c)
        c.toggle("test-cache")
        await c.cleanSelected()

        #expect(box.entries.count == 1)
        let entry = try #require(box.entries.first)
        #expect(entry.targetID == "test-cache")
        #expect(entry.engine == "file")
        #expect(entry.paths == [cache.path])
        #expect(entry.bytesBefore >= 150_000)
        #expect(entry.bytesAfter == 0)
        #expect(entry.removed == 2 && entry.failed == 0 && entry.refused == 0)
    }

    /// The journal file is append-only JSONL, one decodable entry per line.
    @Test func journalAppendsDecodableLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = CleanupJournal.Entry(targetID: "npm", engine: "file",
                                         paths: ["/x"], bytesBefore: 42)
        CleanupJournal.append(entry, directory: dir)
        CleanupJournal.append(entry, directory: dir)

        let text = try String(contentsOf: dir.appendingPathComponent("cleanup.jsonl"),
                              encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CleanupJournal.Entry.self, from: Data(lines[0].utf8))
        #expect(decoded.targetID == "npm")
        #expect(decoded.bytesBefore == 42)
    }

    /// An empty cache on the initial sizing pass is dropped — nothing to
    /// reclaim, the row is noise (the file engine keeps cache roots alive, so
    /// empties are common after a past clean). A row cleaned to 0 B in-session
    /// stays visible: that 0 is the result the user just paid for.
    @Test func emptyRowsAreDroppedOnLoadButKeptAfterCleaning() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty-cache")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyItem = Cleanable(id: "empty-cache", name: "Empty", category: "Test",
                                  icon: "shippingbox", note: "fixture", paths: [empty.path])
        let c = CleanupController(catalog: [Self.cleanable([cache.path]), emptyItem],
                                  allowedRoot: root.path, journal: { _ in })
        c.load()
        await Self.waitForReady(c)
        #expect(c.rows.map(\.id) == ["test-cache"]) // the empty row never appears

        c.toggle("test-cache")
        await c.cleanSelected()
        #expect(c.rows.map(\.id) == ["test-cache"]) // still there, showing its result…
        #expect(c.rows.first?.size == .sized(0))    // …which is 0 B

        c.refresh() // next reload applies the fresh-load rule again
        await Self.waitForReady(c)
        #expect(c.rows.isEmpty)
        #expect(c.state == .ready)
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
        ], allowedRoot: root.path)
        #expect(detected.count == 1)
        #expect(detected[0].paths == [cache.path])
    }

    /// A symlinked cache root is excluded at detection time — the row never
    /// appears, instead of being sized through the link and refused at cleaning
    /// time with gigabytes left on screen.
    @Test func detectRefusesSymlinkedRoot() throws {
        let (root, _) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let detected = CleanupEngine.detect([Self.cleanable([link.path])], allowedRoot: root.path)
        #expect(detected.isEmpty)
    }

    /// detect applies the same resolved-fence rule as clean: a path that passes
    /// the textual prefix but resolves outside the fence is never offered.
    @Test func detectRefusesRelocatedIntermediateComponent() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sm-detect-fence-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        let external = base.appendingPathComponent("external/gradle")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: external.appendingPathComponent("caches"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gradle"), withDestinationURL: external)
        defer { try? fm.removeItem(at: base) }

        let target = home.appendingPathComponent(".gradle/caches").path
        let detected = CleanupEngine.detect([Self.cleanable([target])], allowedRoot: home.path)
        #expect(detected.isEmpty)
    }

    /// A cache root removed by its native cleaner (dotnet deletes its folders
    /// outright) is *empty*, not "Needs access": ENOENT and EACCES are
    /// different stories. First field catch of the operation journal.
    @Test func vanishedRootSizesAsZeroNotDenied() throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("vanished").path
        #expect(CleanupEngine.size(of: Self.cleanable([gone])) == .sized(0))

        // Mixed: the existing path still measures, the vanished one adds nothing.
        guard case .sized(let bytes) = CleanupEngine.size(of: Self.cleanable([cache.path, gone])) else {
            Issue.record("expected .sized for a mixed existing+vanished item")
            return
        }
        #expect(bytes >= 150_000)
    }

    /// An unreadable root (permissions) still reads as denied — that is the
    /// case the "Needs access" row is for.
    @Test func unreadableRootStaysDenied() throws {
        let (root, cache) = try Self.makeFixture()
        defer {
            chmod(cache.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        chmod(cache.path, 0o000)
        #expect(CleanupEngine.size(of: Self.cleanable([cache.path])) == .denied)
    }

    /// clean() on a vanished root reports nothing at all — neither a failure
    /// nor a fence refusal; there is simply nothing to do.
    @Test func cleanTreatsVanishedRootAsNoop() throws {
        let (root, _) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("vanished").path
        let result = CleanupEngine.clean(Self.cleanable([gone]), allowedRoot: root.path)
        #expect(result == CleanupEngine.CleanResult())
    }

    /// size never measures through a symlinked root (ELOOP under O_NOFOLLOW).
    /// detect excludes it anyway; a direct call answers "nothing cleanable
    /// here" (0 B) — not "needs access", which would send the user to grant
    /// Full Disk Access for a relocated cache.
    @Test func sizeNeverMeasuresThroughSymlinkedRoot() throws {
        let (root, _) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: victim.appendingPathComponent("keep.bin"))
        let link = root.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(CleanupEngine.size(of: Self.cleanable([link.path])) == .sized(0))
    }

    // MARK: Discovered targets

    /// Discovery joins the catalog rather than replacing it, and the mode does
    /// not announce `.ready` while the walk is still running — `.ready` is what
    /// makes the Clean button live, so declaring it early would offer a clean of
    /// a list still missing rows.
    @Test func discoveredRowsJoinTheCatalogBeforeReady() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let extra = root.appendingPathComponent("discovered")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data(count: 20_000).write(to: extra.appendingPathComponent("c.bin"))

        let c = CleanupController(
            catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
            discover: { _ in
                [Cleanable(id: "found", name: "Found", category: "Discovered", icon: "x",
                           note: "n", paths: [extra.path], removal: .directory,
                           locationLabel: "1 folder")]
            },
            journal: { _ in })
        c.load()
        await Self.waitForReady(c)

        #expect(c.rows.map(\.id) == ["test-cache", "found"])
        #expect(c.rows.last?.size == .sized(20_480))
        // The discovered row's bytes count toward the mode's total like any
        // other — the strip must not under-report a target it is offering.
        #expect(c.totalFound == c.rows.reduce(0) { $0 + $1.size.bytes })
        #expect(c.totalFound > 20_480)
    }

    /// A discovered target that is not regenerable (orphaned editor state) is
    /// selectable, but never by select-all — same protection the Trash gets, and
    /// from the same flag rather than a second hardcoded id.
    @Test func nonRegenerableDiscoveredRowsAreNeverBulkSelected() async throws {
        let (root, cache) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("orphan")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data(count: 8192).write(to: state.appendingPathComponent("chat.json"))

        let c = CleanupController(
            catalog: [Self.cleanable([cache.path])], allowedRoot: root.path,
            discover: { _ in
                [Cleanable(id: "orphan-state", name: "Orphaned state", category: "Editors",
                           icon: "x", note: "n", paths: [state.path],
                           removal: .directory, regenerable: false)]
            },
            journal: { _ in })
        c.load()
        await Self.waitForReady(c)

        c.toggleAll()
        #expect(c.selectedRows.map(\.id) == ["test-cache"])
        #expect(c.selectAllState == .all) // "all" means all regenerable rows

        c.toggle("orphan-state") // explicit per-row opt-in still works
        #expect(c.selectedRows.count == 2)
    }

    /// The app-liveness gate is declared by the target, not by a case per app:
    /// any `ownerBundleID` blocks while that app runs, and nothing blocks when
    /// it doesn't.
    @Test func ownerBundleIDBlocksWhileItsAppRuns() throws {
        let item = Cleanable(id: "chrome-cache", name: "Chrome cache", category: "Browsers",
                             icon: "globe", note: "n", paths: ["/tmp/x"],
                             ownerBundleID: "com.google.Chrome")

        let blocked = CleanupEngine.blockedReason(for: item, home: "/tmp", isRunning: { _ in true })
        #expect(blocked == "Chrome is running — quit it first, or it keeps writing to these files")
        #expect(CleanupEngine.blockedReason(for: item, home: "/tmp", isRunning: { _ in false }) == nil)

        // A target without an owner is unaffected by whatever is running.
        let anonymous = Self.cleanable(["/tmp/x"])
        #expect(CleanupEngine.blockedReason(for: anonymous, home: "/tmp", isRunning: { _ in true }) == nil)
    }
}

/// Serialized call counter usable from `@Sendable` closures in tests.
private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Journal collector — the controller calls it on the main actor.
@MainActor
private final class JournalBox {
    var entries: [CleanupJournal.Entry] = []
}
