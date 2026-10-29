import Foundation
import Testing
@testable import SpaceMatters

/// Safety invariants of the stale-temporary-files target.
///
/// A temporary folder is disposable by contract, so the question is never
/// "is this regenerable" but "is anything still using it". These tests pin the
/// answers that keep a live entry out: ownership, type, sockets, the change
/// time, the names that announce runtime state, and the re-check at clean time.
///
/// A fixture cannot be made old — nothing sets a ctime back — so dormancy is
/// exercised by moving `now` forward instead.
@Suite struct TemporaryFilesTests {

    private static let later = Date().addingTimeInterval(TemporaryFiles.dormancy + 86_400)

    /// A fake temporary folder, resolved (the fence compares resolved paths,
    /// and `$TMPDIR` sits behind the `/var` → `/private/var` link).
    private static func fixture() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(TemporaryFiles.realPath(url.path))
    }

    private static func makeFile(_ root: String, _ relative: String, bytes: Int = 8192) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private static func makeDir(_ root: String, _ relative: String) throws {
        try FileManager.default.createDirectory(atPath: root + "/" + relative,
                                                withIntermediateDirectories: true)
    }

    // MARK: What is offered

    /// The filters in one pass: data the user owns and nothing uses is offered;
    /// runtime-state names, empties, endpoints and links are not.
    @Test func onlyDormantDataOfTheUsersOwnIsOffered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "leftover/data.bin")
        try Self.makeFile(root, "big.log")
        try Self.makeFile(root, ".hidden/data.bin")          // runtime state by convention
        try Self.makeFile(root, "com.apple.thing/data.bin")  // Apple's own
        try Self.makeFile(root, "server.pid")                // a daemon's pid file
        try Self.makeFile(root, "app.lock")
        try Self.makeDir(root, "empty-dir")                  // a lock or a marker, nothing to gain
        try Self.makeFile(root, "empty.txt", bytes: 0)
        try FileManager.default.createSymbolicLink(atPath: root + "/link",
                                                   withDestinationPath: root + "/leftover")
        #expect(mkfifo(root + "/pipe", 0o600) == 0)

        let offered = TemporaryFiles.candidates(roots: [root], now: Self.later).sorted()
        #expect(offered == [root + "/big.log", root + "/leftover"])
    }

    /// Nothing recent is offered: with the real clock, a fixture made a moment
    /// ago is warm through and through.
    @Test func freshEntriesAreNeverOffered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "leftover/data.bin")
        try Self.makeFile(root, "big.log")

        #expect(TemporaryFiles.candidates(roots: [root]).isEmpty)
    }

    /// An unpacked archive keeps its files' original mtimes — npm stamps 1985 —
    /// so the modification time alone would call a tree unpacked a minute ago
    /// forty years old. The change time records when it actually landed.
    @Test func backdatedModificationTimesDoNotMakeAnEntryOld() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "unpacked/package/index.js")
        let ancient = Date(timeIntervalSince1970: 499_162_500) // 1985-10-26
        for relative in ["unpacked/package/index.js", "unpacked/package", "unpacked"] {
            try FileManager.default.setAttributes([.modificationDate: ancient],
                                                  ofItemAtPath: root + "/" + relative)
        }

        #expect(TemporaryFiles.candidates(roots: [root]).isEmpty)
        #expect(!TemporaryFiles.isDormant(root + "/unpacked"))
    }

    /// Removing a file is not activity. macOS's nightly cleaner deletes old
    /// files from `/tmp`, which moves their folder's mtime to midnight; were
    /// that counted, every folder it thinned would look busy for three more
    /// days. A folder counts by its creation, its files by their own times —
    /// and a file written into it still makes it warm.
    @Test func removingFilesDoesNotMakeAFolderRecent() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "session/keep.bin")
        try Self.makeFile(root, "session/old.bin")
        // Times are whole seconds: let two of them pass, then thin the folder
        // the way the nightly cleaner does.
        Thread.sleep(forTimeInterval: 2.1)
        try FileManager.default.removeItem(atPath: root + "/session/old.bin")

        #expect(TemporaryFiles.isDormant(root + "/session", dormancy: 1))
        #expect(TemporaryFiles.candidates(roots: [root], dormancy: 1) == [root + "/session"])

        try Self.makeFile(root, "session/new.bin")
        #expect(!TemporaryFiles.isDormant(root + "/session", dormancy: 1))
    }

    /// A socket or FIFO is someone's live endpoint whatever its age, so the
    /// folder holding it is in use — even deep inside it.
    @Test func aFolderHoldingAnEndpointIsLive() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "agent/state/data.bin")
        try Self.makeDir(root, "agent/a/b/c")
        #expect(mkfifo(root + "/agent/a/b/c/listener", 0o600) == 0)

        #expect(!TemporaryFiles.isDormant(root + "/agent", now: Self.later))
        // `state/` holds no endpoint of its own: like any dormant part of a
        // live tree, it is looked into and offered on its own.
        #expect(TemporaryFiles.candidates(roots: [root], now: Self.later) == [root + "/agent/state"])
    }

    /// The selection rule on its own: the largest dormant subtrees, never a
    /// piece of a dormant one, and the dormant parts of a warm one — the shape
    /// of `claude-<uid>/<project>/<session>`, kept warm by today's session.
    @Test func selectOffersTheLargestDormantSubtrees() {
        let cutoff: Int64 = 1_000
        typealias Node = TemporaryFiles.Node
        let nodes = [
            Node(path: "/t/claude", parent: nil, offerable: true, newest: 10),             // 0
            Node(path: "/t/claude/old-project", parent: 0, offerable: true, newest: 10, hasData: true),
            Node(path: "/t/claude/project", parent: 0, offerable: true, newest: 10),       // 2
            Node(path: "/t/claude/project/old-session", parent: 2, offerable: true, newest: 10, hasData: true),
            Node(path: "/t/claude/project/today", parent: 2, offerable: true, newest: 5_000, hasData: true),
            Node(path: "/t/claude/.state", parent: 0, offerable: false, newest: 10, hasData: true),
            Node(path: "/t/old", parent: nil, offerable: true, newest: 10, hasData: true),  // 6
            Node(path: "/t/old/inner", parent: 6, offerable: true, newest: 10, hasData: true),
            Node(path: "/t/empty", parent: nil, offerable: true, newest: 10),
        ]
        #expect(TemporaryFiles.select(nodes, cutoff: cutoff) == [
            "/t/claude/old-project", "/t/claude/project/old-session", "/t/old",
        ])
    }

    // MARK: Fence and clean

    /// The temporary fence is its own: strictly inside a temporary folder once
    /// resolved, a real file or folder, never a link — and the home fence does
    /// not let a temporary path through either.
    @Test func temporaryFenceRefusesLinksEscapesAndTheRootItself() throws {
        let root = try Self.fixture()
        let outside = try Self.fixture()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try Self.makeFile(root, "leftover/data.bin")
        try Self.makeFile(outside, "victim/keep.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/link",
                                                   withDestinationPath: outside + "/victim")

        #expect(TemporaryFiles.passesFence(root + "/leftover", roots: [root]))
        #expect(!TemporaryFiles.passesFence(root, roots: [root]))
        #expect(!TemporaryFiles.passesFence(root + "/link", roots: [root]))
        #expect(!TemporaryFiles.passesFence(root + "/link/keep.bin", roots: [root]))
        #expect(!TemporaryFiles.passesFence(outside + "/victim", roots: [root]))

        let item = TemporaryFiles.row([root + "/leftover", root + "/link"], locationLabel: "x")
        #expect(CleanupEngine.detect([item], allowedRoot: outside, temporaryRoots: [root]).first?.paths
                == [root + "/leftover"])
        #expect(CleanupEngine.detect([item], allowedRoot: outside, temporaryRoots: []).isEmpty)
        // A home-fenced target pointed into a temporary folder gets nothing.
        var homeFenced = item
        homeFenced.fence = .home
        #expect(CleanupEngine.detect([homeFenced], allowedRoot: outside, temporaryRoots: [root]).isEmpty)
    }

    /// Cleaning asks discovery's question again. An entry still dormant goes,
    /// file or folder; one that came back to life is left and counted as in
    /// use; one that no longer passes the fence is refused; a link is removed
    /// never, its target never reached.
    @Test func cleanRemovesOnlyWhatIsStillDormant() throws {
        let root = try Self.fixture()
        let outside = try Self.fixture()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try Self.makeFile(root, "leftover/data.bin")
        try Self.makeFile(root, "big.log")
        try Self.makeFile(outside, "victim/keep.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/link",
                                                   withDestinationPath: outside + "/victim")
        let item = TemporaryFiles.row([root + "/leftover", root + "/big.log", root + "/link",
                                       root + "/vanished"],
                                      locationLabel: "x")

        // Same clock as now: everything here is warm, nothing is touched.
        let warm = CleanupEngine.cleanTemporary(item, roots: [root])
        #expect(warm == CleanupEngine.CleanResult(removed: 0, failed: 2, refused: 1))
        #expect(FileManager.default.fileExists(atPath: root + "/leftover/data.bin"))

        let cold = CleanupEngine.cleanTemporary(item, roots: [root], now: Self.later)
        #expect(cold == CleanupEngine.CleanResult(removed: 2, failed: 0, refused: 1))
        #expect(!FileManager.default.fileExists(atPath: root + "/leftover"))
        #expect(!FileManager.default.fileExists(atPath: root + "/big.log"))
        #expect(FileManager.default.fileExists(atPath: outside + "/victim/keep.bin"))
    }

    /// A temporary target can hold loose files, and they count: sizing adds
    /// their blocks to the folders' walk.
    @Test func sizingCountsLooseFiles() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Self.makeFile(root, "leftover/data.bin", bytes: 20_000)
        try Self.makeFile(root, "big.log", bytes: 20_000)

        let item = TemporaryFiles.row([root + "/leftover", root + "/big.log"], locationLabel: "x")
        #expect(CleanupEngine.size(of: item) == .sized(2 * 20_480))
    }

    // MARK: Roots

    /// The roots come from the system, never from `$TMPDIR`, and none of them
    /// can be `/`, the home, or anything around it — the guard that keeps a
    /// stray environment variable from turning Documents into a leftover.
    @Test func rootsAreTheSystemTemporaryFoldersOnly() throws {
        let roots = TemporaryFiles.roots()
        let home = try #require(TemporaryFiles.realPath(NSHomeDirectory()))
        #expect(roots.contains("/private/tmp"))
        #expect(!roots.contains("/private/var/tmp")) // survives reboots: kept on purpose
        for root in roots {
            #expect(root != "/")
            #expect(!home.hasPrefix(root + "/") && root != home && !root.hasPrefix(home + "/"))
        }
    }
}
