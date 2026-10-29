import Foundation

/// The user's own leftovers in the temporary folders: entries nothing has
/// written to for days.
///
/// macOS empties `/private/tmp` at boot and, every night at midnight, deletes
/// the files there nobody has read, written or changed for more than three
/// whole days (`com.apple.tmp_cleaner`, i.e. `find -atime +3 -mtime +3
/// -ctime +3`). That still leaves four days of whatever every tool parked
/// there — 17 GiB on the machine this was written for, nearly all of it
/// Claude Code session scratchpads — and it never touches `$TMPDIR`, where
/// the leftovers of a long uptime pile up.
///
/// The argument here is neither the catalog's (a constant path, argued in
/// prose) nor discovery's (a marker beside the candidate). A temporary folder
/// is disposable by contract — what has to be shown is only that nothing still
/// *uses* an entry. Each rule below answers that, and fails closed:
///
/// - **ownership** — only the user's own entries; anyone else's are not ours
///   to judge (and could not be removed anyway);
/// - **type** — regular files and directories only. Sockets and FIFOs are live
///   endpoints whatever their age, and a directory holding one is in use;
/// - **dormancy** — no file in the entry written, created or renamed, and no
///   folder in it created, for `dormancy`. A file's *change* time counts as
///   well as its modification time: an unpacked archive keeps its files'
///   original mtimes (npm stamps 1985), while the ctime, which nothing can set
///   back, records when they landed. A folder counts by its *creation* time
///   only: its mtime moves whenever an entry is removed, and the nightly
///   cleaner removing old files would otherwise make every folder it thinned
///   look busy — the same reason the scanner leaves directory mtimes out of
///   `newestMTime`;
/// - **legibility** — a directory the walk cannot read entirely, or one with a
///   filesystem mounted inside, cannot be vouched for, so it is not offered;
/// - **names** — hidden entries (`.X11-unix`, the .NET runtime's named
///   mutexes), Apple's own (`com.apple.*`) and lock or pid files are runtime
///   state rather than leftovers, and empty entries are often locks or markers
///   with nothing to gain. None of them is offered.
///
/// Granularity: a warm directory is looked into, down to `maxDepth`, so the
/// dormant parts of a live tree are still found. `claude-<uid>/<project>/
/// <session>` is the motivating shape — a folder kept warm by today's session
/// while it holds weeks of abandoned ones. Loose files are offered only at the
/// top of a temporary folder: inside a live folder, a file untouched for days is
/// more likely a configuration read at every start than a leftover.
///
/// The ages are re-checked when the clean runs (`isDormant`): the window can
/// stay open for days, and an entry that came back to life since is left alone.
enum TemporaryFiles {

    /// Untouched for this long before anything is offered — the threshold
    /// macOS's own nightly cleaner applies to `/tmp`.
    static let dormancy: TimeInterval = 3 * 86_400

    /// How far below a temporary folder a warm directory is looked into.
    static let maxDepth = 3

    static let targetID = "temporary-files"

    /// The temporary folders, fully resolved: the shared `/private/tmp` and the
    /// per-user one every app is handed as `$TMPDIR`. `/private/var/tmp` is left
    /// out on purpose — it is the one that survives reboots, so what sits there
    /// was put there to last.
    ///
    /// The per-user folder comes from `confstr`, never from `$TMPDIR`: the
    /// environment can say anything, and a `TMPDIR` pointing at the home would
    /// turn Documents into a temporary file. For the same reason no root may
    /// contain the home, sit inside it, or be `/`.
    static func roots() -> [String] {
        var candidates = ["/tmp"]
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                candidates.append(String(cString: buffer))
            }
        }
        let home = realPath(NSHomeDirectory())
        var out: [String] = []
        for path in candidates {
            guard let real = realPath(path), real != "/" else { continue }
            if let home, home == real || home.hasPrefix(real + "/") || real.hasPrefix(home + "/") {
                continue
            }
            if !out.contains(real) { out.append(real) }
        }
        return out
    }

    // MARK: Discovery

    /// The row for the Low-Hanging Fruits mode, built from `paths` (empty for
    /// the stand-in shown while the walk runs).
    static func row(_ paths: [String], locationLabel: String) -> Cleanable {
        Cleanable(
            id: targetID, name: "Stale temporary files", category: "System", icon: "hourglass",
            note: "Yours, untouched for 3 days. Sockets and recent writes are left alone.",
            paths: paths, regenerable: false, fence: .temporary,
            locationLabel: locationLabel)
    }

    /// The target, or nil when no temporary folder holds anything dormant.
    static func discover(roots: [String], now: Date = Date()) -> Cleanable? {
        let found = candidates(roots: roots, now: now)
        guard !found.isEmpty else { return nil }
        return row(found.sorted(),
                   locationLabel: "\(found.count) item\(found.count == 1 ? "" : "s") in \(rootsLabel(roots))")
    }

    /// "/tmp · $TMPDIR" — the folders as the user knows them, not as resolved.
    static func rootsLabel(_ roots: [String]) -> String {
        let tmp = realPath("/tmp")
        return roots.map { $0 == tmp ? "/tmp" : "$TMPDIR" }.joined(separator: " · ")
    }

    /// Every dormant entry of the user's own in `roots`.
    static func candidates(roots: [String], uid: uid_t = getuid(), now: Date = Date(),
                           dormancy: TimeInterval = dormancy, maxDepth: Int = maxDepth) -> [String] {
        let cutoff = Int64(now.timeIntervalSince1970 - dormancy)
        var files: [String] = []
        var tops: [Node] = []
        for root in roots {
            var rootStat = stat()
            guard lstat(root, &rootStat) == 0,
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in entries where isOfferable(name) {
                let path = root + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, st.st_uid == uid else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFREG:
                    if fileActivity(st) < cutoff, st.st_blocks > 0 { files.append(path) }
                case S_IFDIR:
                    // Another filesystem mounted here is not a leftover.
                    guard st.st_dev == rootStat.st_dev else { continue }
                    tops.append(Node(path: path, parent: nil, offerable: true,
                                     newest: Int64(st.st_birthtimespec.tv_sec)))
                default:
                    continue // sockets, FIFOs, symlinks, devices
                }
            }
        }
        return files + select(walk(tops, maxDepth: maxDepth, cutoff: cutoff), cutoff: cutoff)
    }

    /// True while nothing in `path` has changed for `dormancy` and nothing in
    /// it is a live endpoint — the same verdict discovery reached, re-asked
    /// just before deleting.
    static func isDormant(_ path: String, now: Date = Date(), dormancy: TimeInterval = dormancy) -> Bool {
        let cutoff = Int64(now.timeIntervalSince1970 - dormancy)
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            return fileActivity(st) < cutoff
        case S_IFDIR:
            let birth = Int64(st.st_birthtimespec.tv_sec)
            let node = rollUp(walk([Node(path: path, parent: nil, offerable: true, newest: birth)],
                                   maxDepth: 1, cutoff: cutoff))[0]
            return !node.live && node.newest < cutoff
        default:
            return false
        }
    }

    /// The temporary fence: strictly inside one of `roots` once fully
    /// resolved, a real file or directory (not a symlink), owned by `uid`.
    /// `realpath(3)` rather than `URL.resolvingSymlinksInPath`, which strips
    /// `/private` from exactly the paths this fence is about.
    static func passesFence(_ path: String, roots: [String], uid: uid_t = getuid()) -> Bool {
        guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == uid else { return false }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR, let real = realPath(path) else { return false }
        return roots.contains { root in
            guard let realRoot = realPath(root) else { return false }
            return real.hasPrefix(realRoot + "/")
        }
    }

    /// Names that announce runtime state rather than a leftover. Applied at
    /// every level: such an entry still counts toward its parent's age, it is
    /// just never offered on its own.
    static func isOfferable(_ name: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("com.apple.") { return false }
        let lower = name.lowercased()
        return ![".lock", ".lck", ".pid"].contains { lower.hasSuffix($0) }
    }

    // MARK: Walk

    /// One directory down to `maxDepth`, with what its whole subtree says.
    struct Node {
        let path: String
        let parent: Int?
        let offerable: Bool
        /// Newest sign of activity anywhere in the subtree: a file's
        /// modification or change, a folder's creation. Unix seconds.
        var newest: Int64
        /// Holds a socket, FIFO or device, a mount, or something unreadable.
        var live = false
        /// At least one file with blocks on disk.
        var hasData = false
    }

    /// Fold every node into its parent, so each one describes its whole
    /// subtree. Children are always created after their parent, so a single
    /// reverse pass suffices.
    static func rollUp(_ nodes: [Node]) -> [Node] {
        var nodes = nodes
        for idx in nodes.indices.reversed() {
            guard let parent = nodes[idx].parent else { continue }
            nodes[parent].newest = max(nodes[parent].newest, nodes[idx].newest)
            nodes[parent].live = nodes[parent].live || nodes[idx].live
            nodes[parent].hasData = nodes[parent].hasData || nodes[idx].hasData
        }
        return nodes
    }

    /// The largest dormant subtrees. A dormant node is offered whole or not at
    /// all — never in pieces; a warm or live one is looked into.
    static func select(_ walked: [Node], cutoff: Int64) -> [String] {
        let nodes = rollUp(walked)
        var children = [[Int]](repeating: [], count: nodes.count)
        for idx in nodes.indices { if let parent = nodes[idx].parent { children[parent].append(idx) } }

        var out: [String] = []
        func visit(_ idx: Int) {
            let node = nodes[idx]
            guard node.offerable else { return }
            if !node.live && node.newest < cutoff {
                if node.hasData { out.append(node.path) }
                return
            }
            children[idx].forEach(visit)
        }
        for idx in nodes.indices where nodes[idx].parent == nil { visit(idx) }
        return out
    }

    /// Walk every node's subtree in full, creating nodes for the directories
    /// down to `maxDepth` and folding everything deeper into its ancestor at
    /// that depth.
    ///
    /// Level by level, each level spread over a worker pool: a serial
    /// `lstat` walk of the 1.2 M entries behind the measurement above took a
    /// minute. `getattrlistbulk` returns a directory's names, types and times
    /// in a few syscalls, which is what makes the walk affordable at all.
    ///
    /// Below `maxDepth`, a subtree whose node is already warm or live is not
    /// read any further: nothing in it can change that verdict, and the
    /// verdict is all the caller uses. That is also what makes the re-check
    /// at clean time cheap for an entry that came back to life.
    static func walk(_ tops: [Node], maxDepth: Int, cutoff: Int64) -> [Node] {
        let state = WalkState(nodes: tops, maxDepth: maxDepth, cutoff: cutoff)
        var level = tops.indices.map { WalkState.Work(path: tops[$0].path, node: $0, depth: 1) }
        let workers = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        while !level.isEmpty {
            state.begin(level)
            DispatchQueue.concurrentPerform(iterations: min(workers, level.count)) { _ in
                state.drain()
            }
            level = state.next
        }
        return state.nodes
    }

    private static func fileActivity(_ st: stat) -> Int64 {
        max(Int64(st.st_mtimespec.tv_sec), Int64(st.st_ctimespec.tv_sec))
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Shared state of one `TemporaryFiles.walk`. Workers only take the lock to
/// claim a directory and to publish what they read from it — never around a
/// syscall.
private final class WalkState: @unchecked Sendable {
    struct Work {
        let path: String
        /// The node this directory's contents fold into: itself down to
        /// `maxDepth`, its ancestor at that depth below it.
        let node: Int
        let depth: Int
    }

    private static let bufferSize = 256 * 1024
    private let lock = NSLock()
    private let maxDepth: Int
    private let cutoff: Int64
    private(set) var nodes: [TemporaryFiles.Node]
    private var level: [Work] = []
    private var cursor = 0
    private(set) var next: [Work] = []

    init(nodes: [TemporaryFiles.Node], maxDepth: Int, cutoff: Int64) {
        self.nodes = nodes
        self.maxDepth = maxDepth
        self.cutoff = cutoff
    }

    func begin(_ level: [Work]) {
        self.level = level
        cursor = 0
        next = []
    }

    func drain() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while let work = claim() { read(work, buffer: buffer) }
    }

    private func claim() -> Work? {
        lock.lock(); defer { lock.unlock() }
        while cursor < level.count {
            let work = level[cursor]
            cursor += 1
            // From the last level of nodes down, a directory only feeds a
            // verdict — and once that verdict is "in use", nothing overturns it.
            let node = nodes[work.node]
            if work.depth >= maxDepth, node.live || node.newest >= cutoff { continue }
            return work
        }
        return nil
    }

    private func read(_ work: Work, buffer: UnsafeMutableRawPointer) {
        var newest: Int64 = 0
        var live = false
        var hasData = false
        var subdirs: [(name: String, time: Int64)] = []

        let fd = open(work.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            live = true // cannot read it, cannot vouch for it
        } else {
            let errors = enumerateDirectory(fd: fd, buffer: buffer, bufferSize: Self.bufferSize,
                                            activityTimes: true) { entry in
                // A folder counts by its creation alone (see `TemporaryFiles`).
                let time = entry.isDirectory ? entry.creationTime : max(entry.modTime, entry.changeTime)
                if entry.isDirectory {
                    if entry.isMountPoint { live = true; return } // never crossed
                    let name = String(decoding: UnsafeRawBufferPointer(start: entry.name, count: entry.nameLength),
                                      as: UTF8.self)
                    subdirs.append((name, time))
                } else if entry.objectType == FSAttr.vreg || entry.objectType == FSAttr.vlnk {
                    newest = max(newest, time)
                    if entry.physicalSize > 0 { hasData = true }
                } else {
                    live = true // socket, FIFO, device — someone's endpoint
                }
            }
            close(fd)
            if errors > 0 { live = true }
        }

        lock.lock(); defer { lock.unlock() }
        nodes[work.node].newest = max(nodes[work.node].newest, newest)
        nodes[work.node].live = nodes[work.node].live || live
        nodes[work.node].hasData = nodes[work.node].hasData || hasData
        let prefix = work.path + "/"
        for sub in subdirs {
            let path = prefix + sub.name
            if work.depth < maxDepth {
                nodes.append(TemporaryFiles.Node(path: path, parent: work.node,
                                                 offerable: TemporaryFiles.isOfferable(sub.name),
                                                 newest: sub.time))
                next.append(Work(path: path, node: nodes.count - 1, depth: work.depth + 1))
            } else {
                nodes[work.node].newest = max(nodes[work.node].newest, sub.time)
                next.append(Work(path: path, node: work.node, depth: work.depth + 1))
            }
        }
    }
}
