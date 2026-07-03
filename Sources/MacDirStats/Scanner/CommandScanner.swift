import Foundation
import Synchronization

/// Scans a filesystem that isn't reachable by host syscalls (inside a Podman or
/// Colima VM) by running a streamed `find` over SSH and parsing its output **as
/// it arrives**. Output format (one record per line):
///
///     <type>\t<blocks>\t<bytes>\t<path>
///
/// where blocks are 512-byte units (→ on-disk size) and bytes is the logical
/// size. We read the pipe incrementally (never block until completion), so the
/// tree and sizes fill in live exactly like the local scanner.
final class CommandScanner: ScanBackend {
    let root: FSNode
    private let rootPath: String
    private let executable: String
    private let arguments: [String]
    let source: ScanSource

    private let dirCountAtomic = Atomic<Int64>(0)
    private let errAtomic = Atomic<Int64>(0)

    private var process: Process?
    private var thread: Thread?
    private let finishLock = NSLock()
    private var finished = false
    private let cancelledFlag = Atomic<Bool>(false)

    private let failureLock = NSLock()
    private var _failure: String?
    var failure: String? { failureLock.lock(); defer { failureLock.unlock() }; return _failure }
    private func setFailure(_ msg: String) { failureLock.lock(); if _failure == nil { _failure = msg }; failureLock.unlock() }

    // Touched only by the single reader thread.
    private var nodes: [String: FSNode] = [:]
    private var largestFile: [ObjectIdentifier: Int64] = [:]

    private let extLock = NSLock()
    private var extStats: [ExtKey: ExtStat] = [:]

    init(root: FSNode, rootPath: String, executable: String, arguments: [String], source: ScanSource) {
        self.root = root
        self.rootPath = rootPath
        self.executable = executable
        self.arguments = arguments
        self.source = source
    }

    func diagnostics() -> String {
        "\(executable) \(arguments.joined(separator: " "))"
    }

    // MARK: ScanBackend

    func start() {
        nodes[rootPath] = root

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.process = process

        let thread = Thread { [weak self] in
            self?.readLoop(outPipe.fileHandleForReading, errHandle: errPipe.fileHandleForReading, process: process)
        }
        thread.stackSize = 4 << 20
        thread.name = "macdirstats.vm-scanner"
        self.thread = thread

        do {
            try process.run()
        } catch {
            errAtomic.wrappingAdd(1, ordering: .relaxed)
            setFailure("Could not launch the scan command: \(error.localizedDescription)")
            markFinished()
            return
        }
        thread.start()
    }

    func cancel() {
        cancelledFlag.store(true, ordering: .relaxed)
        process?.terminate() // closes stdout → the reader loop sees EOF and stops
        markFinished()
    }

    var isFinished: Bool {
        finishLock.lock(); defer { finishLock.unlock() }
        return finished
    }

    var directoryCount: Int64 { dirCountAtomic.load(ordering: .relaxed) }
    var scanErrorCount: Int64 { errAtomic.load(ordering: .relaxed) }

    func snapshotExtensions(metric: SizeMetric, limit: Int) -> [ExtRow] {
        extLock.lock()
        let copy = extStats
        extLock.unlock()

        var rows = copy.map { key, stat in
            ExtRow(key: key, name: key.displayName, logical: stat.logical, physical: stat.physical, count: stat.count)
        }
        rows.sort { metric == .physical ? $0.physical > $1.physical : $0.logical > $1.logical }
        if rows.count > limit { rows.removeLast(rows.count - limit) }
        return rows
    }

    // MARK: Streaming reader

    private func readLoop(_ handle: FileHandle, errHandle: FileHandle, process: Process) {
        // Drain stderr concurrently: `find` can emit many "Permission denied"
        // lines, which would otherwise fill the stderr pipe and deadlock stdout.
        let errBox = Mutex<Data>(Data())
        let errThread = Thread { errBox.withLock { $0 = errHandle.readDataToEndOfFile() } }
        errThread.stackSize = 1 << 20
        errThread.start()

        var pending = Data()
        while true {
            let chunk = handle.availableData // returns as soon as bytes arrive; empty == EOF
            if chunk.isEmpty { break }
            if cancelledFlag.load(ordering: .relaxed) { break } // stop feeding the tree after Stop
            pending.append(chunk)

            // Parse every complete NUL-terminated record; keep the remainder.
            var searchStart = pending.startIndex
            while let nul = pending[searchStart...].firstIndex(of: 0x00) {
                parse(pending[searchStart..<nul])
                searchStart = pending.index(after: nul)
            }
            if searchStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<searchStart)
            }
        }
        if !cancelledFlag.load(ordering: .relaxed), !pending.isEmpty { parse(pending[...]) }
        flushAccumulator() // propagate the final directory's batch

        process.waitUntilExit()
        while errThread.isExecuting { usleep(2000) } // let stderr finish (EOF after exit)

        // Diagnose a hard failure: a non-zero exit, or a "successful" run that
        // produced nothing (busybox `find` without -printf, missing stdbuf, sudo
        // denied) — the difference between "empty volume" and "broken scan".
        if !cancelledFlag.load(ordering: .relaxed) {
            let errText = errBox.withLock { String(decoding: $0, as: UTF8.self) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = process.terminationStatus
            let produced = root.fileCount.load(ordering: .relaxed) > 0 || dirCountAtomic.load(ordering: .relaxed) > 1
            if code != 0 {
                setFailure("Scan command failed (exit \(code)).\(errText.isEmpty ? "" : "\n\(String(errText.prefix(400)))")")
            } else if !produced {
                setFailure("Scan produced no results — the VM may lack GNU find / stdbuf, or sudo was denied.\(errText.isEmpty ? "" : "\n\(String(errText.prefix(400)))")")
            }
        }

        nodes.removeAll()
        largestFile.removeAll()
        markFinished()
    }

    private func parse(_ line: Data) {
        let bytes = [UInt8](line)
        guard bytes.count >= 7 else { return }

        var t1 = -1, t2 = -1, t3 = -1
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x09 {
                if t1 < 0 { t1 = i }
                else if t2 < 0 { t2 = i }
                else { t3 = i; break }
            }
            i += 1
        }
        guard t1 >= 1, t2 > t1, t3 > t2, t3 + 1 < bytes.count else { return }

        let type = bytes[0]
        let blocks = asciiInt(bytes, t1 + 1, t2)
        let logical = asciiInt(bytes, t2 + 1, t3)
        let physical = blocks * 512
        let path = String(decoding: bytes[(t3 + 1)...], as: UTF8.self)

        if type == 0x64 { // 'd' directory
            if path == rootPath || nodes[path] != nil {
                dirCountAtomic.wrappingAdd(1, ordering: .relaxed)
                return
            }
            let (parentPath, name) = Self.split(path)
            let parent = nodes[parentPath] ?? root
            let node = FSNode(name: name, parent: parent, isDirectory: true)
            parent.appendChild(node)
            nodes[path] = node
            dirCountAtomic.wrappingAdd(1, ordering: .relaxed)
        } else { // file, symlink, etc.
            let (parentPath, name) = Self.split(path)
            let parent = nodes[parentPath] ?? root
            // `find` lists a directory's files consecutively: accumulate them and
            // walk the ancestor chain once per directory, not once per file.
            if parent !== accParent { flushAccumulator() }
            accParent = parent
            accLogical += logical; accPhysical += physical; accCount += 1

            let key = ExtKey(fileName: name)
            extLock.lock()
            extStats[key, default: ExtStat()].add(logical: logical, physical: physical)
            extLock.unlock()

            // Colour the folder by its largest file's type (cheap, looks right).
            let pid = ObjectIdentifier(parent)
            if physical > (largestFile[pid] ?? -1) {
                largestFile[pid] = physical
                parent.updateDominantExt(key)
            }
        }
    }

    // Batched ancestor propagation (see file branch above).
    private var accParent: FSNode?
    private var accLogical: Int64 = 0
    private var accPhysical: Int64 = 0
    private var accCount: Int64 = 0

    private func flushAccumulator() {
        guard let parent = accParent, accCount > 0 else { accParent = nil; return }
        parent.adjustDirectFiles(logical: accLogical, physical: accPhysical, count: accCount)
        var node: FSNode? = parent
        while let cur = node {
            cur.aggLogical.wrappingAdd(accLogical, ordering: .relaxed)
            cur.aggPhysical.wrappingAdd(accPhysical, ordering: .relaxed)
            cur.fileCount.wrappingAdd(accCount, ordering: .relaxed)
            node = cur.parent
        }
        accParent = nil; accLogical = 0; accPhysical = 0; accCount = 0
    }

    private func asciiInt(_ b: [UInt8], _ lo: Int, _ hi: Int) -> Int64 {
        var value: Int64 = 0
        var i = lo
        while i < hi {
            let c = b[i]
            if c >= 0x30 && c <= 0x39 { value = value * 10 + Int64(c - 0x30) }
            i += 1
        }
        return value
    }

    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let idx = path.lastIndex(of: "/") else { return ("/", path) }
        if idx == path.startIndex { return ("/", String(path[path.index(after: idx)...])) }
        return (String(path[..<idx]), String(path[path.index(after: idx)...]))
    }

    private func markFinished() {
        finishLock.lock(); finished = true; finishLock.unlock()
    }
}
