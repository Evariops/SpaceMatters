import Foundation

/// What a scan looks like to the MCP tools, independent of where it came from.
///
/// Two implementations back it: `DetachedScanSource` owns a scan of its own
/// (the `--mcp` process running alone), and `LiveScanSource` reads the running
/// app's tree over the socket (SPEC-14 §3.5). The tools are written once against
/// this, so connected mode gains nothing to maintain except the mutations that
/// only make sense there.
protocol MCPScanSource: AnyObject, Sendable {
    /// Blocking: scans if it must. Called from whichever thread serves the
    /// request, so implementations own their own synchronisation.
    func index() throws -> TreeQuery.Index
    func stats() -> MCPScanStats
    /// The exact, scan-wide extension table. Empty when unavailable.
    func exactTypes() -> [ExtRow]

    /// Verdict painting and view control exist only against a running app.
    var supportsMap: Bool { get }
    func annotate(path: String, verdict: Verdict, reason: String) throws
    func focus(path: String) throws
}

extension MCPScanSource {
    var supportsMap: Bool { false }
    func annotate(path: String, verdict: Verdict, reason: String) throws {
        throw MCPScanError(message: "annotate needs the SpaceMatters app running — this session "
            + "is attached to a standalone scan, which has no map to paint on.")
    }
    func focus(path: String) throws {
        throw MCPScanError(message: "focus needs the SpaceMatters app running.")
    }
}

struct MCPScanError: Error { let message: String }

struct MCPScanStats: Sendable {
    var rootPath: String
    var rootName: String = ""
    var files: Int64 = 0
    var dirs: Int64?
    var errors: Int64 = 0
    var elapsed: TimeInterval = 0
    var date: Date?
    var counting: CountingMode = .attribution
    var hasFullDiskAccess: Bool = false
    /// True when the numbers come from the app the user is looking at.
    var isLive: Bool = false
    /// Non-nil when something about this scan makes paths or totals unusable —
    /// reported instead of quietly emitting wrong ones.
    var limitation: String?
}

/// A scan this process performs and owns. The MCP server lives as long as the
/// session, so the walk is paid once on the first tool call and every later call
/// is a read over memory.
///
/// `@unchecked Sendable`: the tree is published once, complete, before any
/// reader sees it, and `FSNode` reads are atomic or lock-guarded by design.
final class DetachedScanSource: MCPScanSource, @unchecked Sendable {

    private let rootPath: String
    private let lock = NSLock()
    private var built: TreeQuery.Index?
    private var scanStats: MCPScanStats
    private var types: [ExtRow] = []

    init(rootPath: String) {
        self.rootPath = rootPath
        self.scanStats = MCPScanStats(rootPath: rootPath, hasFullDiskAccess: FullDiskAccess.isGranted)
    }

    func index() throws -> TreeQuery.Index {
        lock.lock()
        defer { lock.unlock() }
        if let built { return built }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            throw MCPScanError(message: "scan root does not exist: \(rootPath)")
        }
        JSONRPC.log("scanning \(rootPath)…")
        let url = URL(fileURLWithPath: rootPath)
        let root = FSNode(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(
            root: root, seeds: [.init(path: rootPath, node: root)],
            skipPaths: DirectoryScanner.recommendedSkipPaths(seedPaths: [rootPath]))
        let start = Date()
        scanner.start()
        while !scanner.isFinished { usleep(20_000) }

        scanStats.rootName = root.name
        scanStats.files = root.fileCount.load(ordering: .relaxed)
        scanStats.dirs = scanner.dirCount.load(ordering: .relaxed)
        scanStats.errors = scanner.errorCount.load(ordering: .relaxed)
        scanStats.elapsed = Date().timeIntervalSince(start)
        scanStats.date = Date()
        types = scanner.snapshotExtensions(limit: 25)

        let index = TreeQuery.Index(root: root, rootPath: rootPath)
        built = index
        JSONRPC.log(String(format: "scanned %@ in %.1fs — %lld files, %lld dirs, %lld unreadable",
                           Format.bytes(root.sizeOnDisk), scanStats.elapsed,
                           scanStats.files, scanStats.dirs ?? 0, scanStats.errors))
        return index
    }

    func stats() -> MCPScanStats {
        lock.lock(); defer { lock.unlock() }
        return scanStats
    }

    func exactTypes() -> [ExtRow] {
        lock.lock(); defer { lock.unlock() }
        return types
    }
}
