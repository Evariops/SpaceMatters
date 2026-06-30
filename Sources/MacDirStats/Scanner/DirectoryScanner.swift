import Foundation
import Synchronization

/// Parallel filesystem scanner.
///
/// A pool of worker threads pulls directories off a shared LIFO stack (depth-first
/// for cache locality), enumerates each with `getattrlistbulk`, accumulates the
/// directory's own files, pushes child directories back onto the stack, and
/// propagates sizes up the ancestor chain via atomics. Termination is detected
/// when the count of in-flight directories returns to zero.
final class DirectoryScanner: ScanBackend {
    let root: FSNode

    var directoryCount: Int64 { dirCount.load(ordering: .relaxed) }
    var scanErrorCount: Int64 { errorCount.load(ordering: .relaxed) }

    /// One starting point of the scan. Multiple seeds let a single scan span
    /// several volumes, all aggregating into a shared (virtual) `root`.
    struct Seed {
        let path: String
        let node: FSNode
    }
    private let seeds: [Seed]

    // Live counters readable from any thread.
    let dirCount = Atomic<Int64>(0)
    let errorCount = Atomic<Int64>(0)

    private struct WorkItem {
        let path: String
        let node: FSNode
    }

    /// Directories to never descend into (e.g. network mounts) — avoids extra TCC
    /// prompts and double-counting.
    private let skipPaths: Set<String>

    private let workerCount: Int
    private var threads: [Thread] = []

    // Pool synchronization.
    private let cond = NSCondition()
    private var stack: [WorkItem] = []
    private var outstanding = 0
    private var finished = false
    private var cancelled = false

    // Per-extension table (merged from each directory under its own lock).
    private let extLock = NSLock()
    private var extStats: [ExtKey: ExtStat] = [:]

    private static let bufferSize = 256 * 1024

    init(root: FSNode, seeds: [Seed], skipPaths: Set<String> = [], workerCount: Int? = nil) {
        self.root = root
        self.seeds = seeds
        self.skipPaths = skipPaths
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // Scanning APFS/SSD is throughput-bound on syscalls; oversubscribe a
        // little but keep it bounded.
        self.workerCount = workerCount ?? max(2, min(cores, 12))
    }

    convenience init(root: FSNode, rootPath: String, workerCount: Int? = nil) {
        self.init(root: root, seeds: [Seed(path: rootPath, node: root)], workerCount: workerCount)
    }

    /// Paths that should not be descended into for a clean local-disk scan:
    /// network mounts, plus the APFS Data volume mount point. The latter is
    /// crucial on macOS — `/Users`, `/Applications`, `/Library`… are *firmlinks*
    /// into `/System/Volumes/Data`, so scanning `/` would otherwise count all user
    /// data twice (once via the firmlink, once via the Data mount).
    static func recommendedSkipPaths(seedPaths: [String]) -> Set<String> {
        let seeds = Set(seedPaths)
        var skip = MountInfo.networkMountPoints().subtracting(seeds)

        let dataVolume = "/System/Volumes/Data"
        let seedInsideData = seeds.contains { $0 == dataVolume || $0.hasPrefix(dataVolume + "/") }
        if !seedInsideData { skip.insert(dataVolume) }
        return skip
    }

    // MARK: Lifecycle

    func start() {
        cond.lock()
        for seed in seeds {
            stack.append(WorkItem(path: seed.path, node: seed.node))
        }
        outstanding = seeds.count
        if seeds.isEmpty { finished = true }
        cond.unlock()

        for i in 0..<workerCount {
            let thread = Thread { [weak self] in self?.workerLoop() }
            thread.name = "macdirstats.scanner.\(i)"
            thread.stackSize = 2 << 20
            threads.append(thread)
            thread.start()
        }
    }

    func cancel() {
        cond.lock()
        cancelled = true
        cond.broadcast()
        cond.unlock()
    }

    var isFinished: Bool {
        cond.lock(); defer { cond.unlock() }
        return finished || cancelled
    }

    /// Snapshot of the top `limit` extensions by `metric`, materialised as rows.
    func snapshotExtensions(metric: SizeMetric, limit: Int) -> [ExtRow] {
        extLock.lock()
        let copy = extStats
        extLock.unlock()

        var rows = copy.map { key, stat in
            ExtRow(key: key, name: key.displayName, logical: stat.logical, physical: stat.physical, count: stat.count)
        }
        rows.sort { a, b in
            metric == .physical ? a.physical > b.physical : a.logical > b.logical
        }
        if rows.count > limit { rows.removeLast(rows.count - limit) }
        return rows
    }

    // MARK: Worker

    private func workerLoop() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            cond.lock()
            while stack.isEmpty && !finished && !cancelled {
                cond.wait()
            }
            if cancelled || finished {
                cond.unlock()
                return
            }
            let item = stack.removeLast()
            cond.unlock()

            let children = process(item, buffer: buffer)

            cond.lock()
            if cancelled {
                cond.unlock()
                return
            }
            if !children.isEmpty {
                stack.append(contentsOf: children)
                outstanding += children.count
                // Wake exactly as many idle workers as there is new work.
                for _ in 0..<children.count { cond.signal() }
            }
            outstanding -= 1
            if outstanding == 0 {
                finished = true
                cond.broadcast()
            }
            cond.unlock()
        }
    }

    /// Read one directory's direct entries. Returns child-directory work items.
    private func process(_ item: WorkItem, buffer: UnsafeMutableRawPointer) -> [WorkItem] {
        let fd = open(item.path, O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            errorCount.wrappingAdd(1, ordering: .relaxed)
            item.node.finishScan(children: [], filesLogical: 0, filesPhysical: 0, fileCount: 0)
            dirCount.wrappingAdd(1, ordering: .relaxed)
            return []
        }
        defer { close(fd) }

        var childItems: [WorkItem] = []
        var childNodes: [FSNode] = []
        var filesLogical: Int64 = 0
        var filesPhysical: Int64 = 0
        var fileCount: Int64 = 0
        var localExt: [ExtKey: ExtStat] = [:]

        // Avoid a double slash when the parent is "/" so paths match skip entries.
        let pathPrefix = item.path == "/" ? "/" : item.path + "/"

        let errors = enumerateDirectory(fd: fd, buffer: buffer, bufferSize: Self.bufferSize) { entry in
            if entry.isDirectory {
                let name = String(
                    decoding: UnsafeRawBufferPointer(start: entry.name, count: entry.nameLength),
                    as: UTF8.self
                )
                let childPath = pathPrefix + name
                if skipPaths.contains(childPath) { return } // network mount / Data firmlink
                let child = FSNode(name: name, parent: item.node, isDirectory: true)
                childNodes.append(child)
                childItems.append(WorkItem(path: childPath, node: child))
            } else {
                filesLogical += entry.logicalSize
                filesPhysical += entry.physicalSize
                fileCount += 1
                let key = ExtKey(name: entry.name, length: entry.nameLength)
                localExt[key, default: ExtStat()].add(logical: entry.logicalSize, physical: entry.physicalSize)
            }
        }
        if errors > 0 {
            errorCount.wrappingAdd(Int64(errors), ordering: .relaxed)
        }

        // Pick the extension that dominates this folder's own files (by bytes).
        var dominantExt: ExtKey = .none
        var dominantBytes: Int64 = -1
        for (key, stat) in localExt {
            let bytes = max(stat.physical, stat.logical)
            if bytes > dominantBytes {
                dominantBytes = bytes
                dominantExt = key
            }
        }

        item.node.finishScan(
            children: childNodes,
            filesLogical: filesLogical,
            filesPhysical: filesPhysical,
            fileCount: fileCount,
            dominantExt: dominantExt
        )

        // Propagate this directory's direct-file totals to itself and every
        // ancestor. Summed across all directories, each node ends up holding the
        // total size of its whole subtree.
        if filesLogical != 0 || filesPhysical != 0 || fileCount != 0 {
            var node: FSNode? = item.node
            while let n = node {
                n.aggLogical.wrappingAdd(filesLogical, ordering: .relaxed)
                n.aggPhysical.wrappingAdd(filesPhysical, ordering: .relaxed)
                n.fileCount.wrappingAdd(fileCount, ordering: .relaxed)
                node = n.parent
            }
        }

        if !localExt.isEmpty {
            extLock.lock()
            for (key, stat) in localExt {
                extStats[key, default: ExtStat()].merge(stat)
            }
            extLock.unlock()
        }

        dirCount.wrappingAdd(1, ordering: .relaxed)
        return childItems
    }
}

/// A row in the file-type breakdown.
struct ExtRow: Identifiable {
    let key: ExtKey
    let name: String
    let logical: Int64
    let physical: Int64
    let count: Int64
    var id: ExtKey { key }

    func size(_ metric: SizeMetric) -> Int64 {
        metric == .physical ? physical : logical
    }
}
