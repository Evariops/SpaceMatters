import Foundation
import Observation
import AppKit

/// Bridges the background scanner to SwiftUI. Owns the scan lifecycle and
/// publishes throttled snapshots: scalar stats and a monotonically increasing
/// `version` the views observe to re-read live atomic sizes from the tree.
@MainActor
@Observable
final class ScanController {
    enum Phase { case idle, scanning, finished, cancelled, failed }

    private(set) var phase: Phase = .idle
    /// Human-readable reason when `phase == .failed` (e.g. VM scan couldn't run).
    private(set) var failureMessage: String?
    private(set) var root: FSNode?
    private(set) var rootPath: String = ""
    private(set) var rootName: String = ""

    // Throttled live stats.
    private(set) var totalLogical: Int64 = 0
    private(set) var totalPhysical: Int64 = 0
    private(set) var fileCount: Int64 = 0
    private(set) var dirCount: Int64 = 0
    private(set) var errorCount: Int64 = 0
    private(set) var filesPerSecond: Double = 0
    private(set) var elapsed: TimeInterval = 0

    /// Bumped on every refresh so size-dependent views recompute.
    private(set) var version: UInt64 = 0
    private(set) var extRows: [ExtRow] = []

    var metric: SizeMetric = .physical {
        didSet { if metric != oldValue { extRows = scanner?.snapshotExtensions(metric: metric, limit: 250) ?? []; bump() } }
    }

    /// The node currently focused in the treemap / selected in the list.
    var selection: FSNode?
    /// The directory the treemap is zoomed into (defaults to root).
    var zoomRoot: FSNode?

    /// Which directories are expanded in the outline (central, so the treemap can
    /// programmatically expand ancestors to reveal a selection).
    var expanded: Set<FSNode> = []
    /// Set to ask the outline to scroll a node into view; cleared once handled.
    var revealTarget: FSNode?

    /// A file type picked in the breakdown panel → its tiles are spotlighted in
    /// the treemap (everything else dims). `nil` = no type filter.
    var selectedExt: ExtKey?
    /// Bumped whenever the treemap highlight (type filter) changes, so the cached
    /// treemap canvas knows to redraw.
    private(set) var highlightVersion: Int = 0

    func toggleExt(_ ext: ExtKey) {
        selectedExt = (selectedExt == ext) ? nil : ext
        if selectedExt != nil { searchQuery = ""; searchDirect = []; searchPath = [] }
        highlightVersion &+= 1
    }

    // MARK: Search

    var searchQuery = ""
    /// Directories whose name matched (bright in the treemap, bold in the tree).
    @ObservationIgnored private(set) var searchDirect: Set<ObjectIdentifier> = []
    /// Matches + their ancestors — the pruned tree shown while searching.
    @ObservationIgnored private var searchPath: Set<ObjectIdentifier> = []

    var isSearching: Bool { !searchQuery.isEmpty }
    func isSearchMatch(_ node: FSNode) -> Bool { searchDirect.contains(ObjectIdentifier(node)) }
    var searchMatchIDs: Set<ObjectIdentifier> { searchDirect }

    @ObservationIgnored private var searchGeneration = 0

    func setSearch(_ query: String) {
        searchQuery = query
        selectedExt = nil
        highlightVersion &+= 1
        searchGeneration += 1
        let gen = searchGeneration
        guard !query.isEmpty, let root else {
            searchDirect = []; searchPath = []; bump(); return
        }
        // Walk the tree off the main thread (up to hundreds of thousands of
        // directories) so typing never hitches; apply the result on the main actor
        // unless a newer keystroke has already superseded this one.
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> (Set<ObjectIdentifier>, Set<ObjectIdentifier>) in
                var direct = Set<ObjectIdentifier>()
                var path = Set<ObjectIdentifier>()
                func walk(_ node: FSNode) {
                    if node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        direct.insert(ObjectIdentifier(node))
                        var p: FSNode? = node
                        while let cur = p { path.insert(ObjectIdentifier(cur)); p = cur.parent }
                    }
                    for child in node.children { walk(child) }
                }
                walk(root)
                return (direct, path)
            }.value
            guard gen == self.searchGeneration else { return }
            self.searchDirect = result.0
            self.searchPath = result.1
            self.bump()
        }
    }

    /// True for local host scans; false for VM scans (whose paths aren't host
    /// paths, so Finder/Trash actions and on-demand file listing don't apply).
    private(set) var isHostScan = true

    private var scanner: (any ScanBackend)?
    private var timer: Timer?
    private var scanActivity: NSObjectProtocol?
    private var startTime = Date()
    private var lastSampleTime = Date()
    private var lastSampleCount: Int64 = 0
    private var tickIndex = 0

    var totalSize: Int64 { metric == .physical ? totalPhysical : totalLogical }

    var isScanning: Bool { phase == .scanning }

    // MARK: Full Disk Access

    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    func refreshFullDiskAccess() { hasFullDiskAccess = FullDiskAccess.isGranted }

    // MARK: Lifecycle

    func chooseFolderAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            scan(url: url)
        }
    }

    /// Remembered for Rescan (so a multi-disk scan rescans the same disks).
    private(set) var lastVolumes: [Volume] = []
    @ObservationIgnored private var lastVM: (machine: VMMachine, scope: VMScope)?

    func scan(url: URL) {
        lastVolumes = []
        lastVM = nil
        let node = FSNode(name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent, parent: nil)
        begin(root: node, seeds: [.init(path: url.path, node: node)], displayPath: url.path)
    }

    /// Scan one or several whole disks. A single disk becomes the root; multiple
    /// disks hang under a virtual root that aggregates their totals.
    func scan(volumes: [Volume]) {
        guard !volumes.isEmpty else { return }
        lastVolumes = volumes
        lastVM = nil

        if volumes.count == 1 {
            let v = volumes[0]
            let node = FSNode(name: v.name, parent: nil)
            begin(root: node, seeds: [.init(path: v.url.path, node: node)], displayPath: v.url.path)
            return
        }

        let root = FSNode(name: "\(volumes.count) disks", parent: nil)
        var children: [FSNode] = []
        var seeds: [DirectoryScanner.Seed] = []
        for v in volumes {
            let node = FSNode(name: v.name, parent: root)
            children.append(node)
            seeds.append(.init(path: v.url.path, node: node))
        }
        root.finishScan(children: children, filesLogical: 0, filesPhysical: 0, fileCount: 0)
        begin(root: root, seeds: seeds, displayPath: "")
    }

    private func begin(root: FSNode, seeds: [DirectoryScanner.Seed], displayPath: String) {
        // Skip network volumes and the APFS Data firmlink mount (avoids double
        // counting), unless one of those is itself a chosen root.
        let skip = DirectoryScanner.recommendedSkipPaths(seedPaths: seeds.map(\.path))
        let scanner = DirectoryScanner(root: root, seeds: seeds, skipPaths: skip)
        var paths: [ObjectIdentifier: String] = [:]
        for seed in seeds { paths[ObjectIdentifier(seed.node)] = seed.path }
        startBackend(root: root, scanner: scanner, displayPath: displayPath, isHost: true, nodePaths: paths)
    }

    /// Scan inside a Podman/Colima VM (streamed `find` over SSH).
    func scanVM(machine: VMMachine, scope: VMScope) {
        guard machine.running else { return }
        lastVolumes = []
        lastVM = (machine, scope)
        let cmd = VMProbe.scanCommand(machine: machine, scope: scope)
        let label = scope == .full ? "VM" : "Containers"
        let node = FSNode(name: "\(machine.runtime.rawValue) — \(label)", parent: nil)
        let scanner = CommandScanner(root: node, rootPath: cmd.rootPath, executable: cmd.executable, arguments: cmd.arguments)
        startBackend(
            root: node,
            scanner: scanner,
            displayPath: cmd.rootPath,
            isHost: false,
            nodePaths: [ObjectIdentifier(node): cmd.rootPath]
        )
    }

    private func startBackend(
        root: FSNode,
        scanner: any ScanBackend,
        displayPath: String,
        isHost: Bool,
        nodePaths: [ObjectIdentifier: String]
    ) {
        cancel()

        self.root = root
        self.zoomRoot = root
        self.selection = root
        self.selectedRowID = .dir(ObjectIdentifier(root))
        self.expanded = [root]
        self.revealTarget = nil
        self.selectedExt = nil
        self.searchQuery = ""; self.searchDirect = []; self.searchPath = []
        self.rootPath = displayPath
        self.rootName = root.name
        self.scanner = scanner
        self.isHostScan = isHost

        sortCache.removeAll()
        fileCache.removeAll()
        self.nodePaths = nodePaths

        totalLogical = 0; totalPhysical = 0; fileCount = 0; dirCount = 0; errorCount = 0
        filesPerSecond = 0; elapsed = 0; extRows = []
        startTime = Date(); lastSampleTime = startTime; lastSampleCount = 0; tickIndex = 0
        failureMessage = nil
        phase = .scanning

        scanner.start()
        startTimer()
        bump()
    }

    func cancel() {
        guard phase == .scanning else { stopTimer(); return }
        scanner?.cancel()
        phase = .cancelled
        refresh(final: true)
        stopTimer()
    }

    func rescan() {
        if let lastVM { scanVM(machine: lastVM.machine, scope: lastVM.scope); return }
        if !lastVolumes.isEmpty { scan(volumes: lastVolumes); return }
        guard !rootPath.isEmpty else { return }
        scan(url: URL(fileURLWithPath: rootPath))
    }

    /// Discard the current scan and return to the disk-selection splash.
    func goHome() {
        scanner?.cancel()
        stopTimer()
        scanner = nil
        root = nil
        zoomRoot = nil
        selection = nil
        selectedRowID = nil
        revealTarget = nil
        expanded = []
        rootPath = ""
        rootName = ""
        lastVolumes = []
        lastVM = nil
        isHostScan = true
        failureMessage = nil
        phase = .idle

        totalLogical = 0; totalPhysical = 0; fileCount = 0; dirCount = 0; errorCount = 0
        filesPerSecond = 0; elapsed = 0; extRows = []
        sortCache.removeAll(); fileCache.removeAll(); nodePaths.removeAll()
        bump()
    }

    // MARK: Outline rows (directories + lazily-listed files)

    /// A file inside a directory. Files aren't kept in the tree (RAM), so they're
    /// listed on demand per expanded folder and cached.
    struct FileItem {
        let name: String
        let logical: Int64
        let physical: Int64
        func size(_ m: SizeMetric) -> Int64 { m == .physical ? physical : logical }
    }

    enum RowID: Hashable {
        case dir(ObjectIdentifier)
        case file(ObjectIdentifier, String) // parent + file name
    }

    /// A flattened outline row: a directory or a file.
    struct OutlineRow: Identifiable {
        enum Kind {
            case directory(FSNode)
            case file(FileItem, parent: FSNode)
        }
        let kind: Kind
        let depth: Int
        let siblingMax: Int64
        let isExpandable: Bool
        let isExpanded: Bool
        let id: RowID
    }

    /// Highlighted row (dirs or files). The treemap separately uses `selection`.
    var selectedRowID: RowID?

    // Caches (not observed).
    @ObservationIgnored private var sortCache: [ObjectIdentifier: [FSNode]] = [:]
    @ObservationIgnored private var sortCacheMetric: SizeMetric = .physical
    /// Cached file listing per directory, tagged with the directory's direct-file
    /// count so it stays valid during a live scan and only re-enumerates the disk
    /// when that directory's contents actually changed.
    private struct FileListing { let count: Int64; let items: [FileItem] }
    @ObservationIgnored private var fileCache: [ObjectIdentifier: FileListing] = [:]
    /// Resolved paths for seed (root/volume) nodes, so any node's full path can be
    /// rebuilt on demand without storing a path on every node.
    @ObservationIgnored private var nodePaths: [ObjectIdentifier: String] = [:]

    private static let maxFilesPerFolder = 2000

    func isExpanded(_ node: FSNode) -> Bool { expanded.contains(node) }

    func toggleExpanded(_ node: FSNode) {
        if expanded.contains(node) { expanded.remove(node) } else { expanded.insert(node) }
    }

    func selectDirectory(_ node: FSNode) {
        selection = node
        selectedRowID = .dir(ObjectIdentifier(node))
    }

    func selectFile(_ file: FileItem, parent: FSNode) {
        selection = parent
        selectedRowID = .file(ObjectIdentifier(parent), file.name)
    }

    /// Children sorted by current metric, cached after the scan so repeated
    /// outline rebuilds are O(1) lookups, not sorts.
    func sortedChildren(_ node: FSNode) -> [FSNode] {
        let children = node.children
        if phase == .scanning {
            return children.sorted { $0.size(metric) > $1.size(metric) }
        }
        if sortCacheMetric != metric { sortCache.removeAll(); sortCacheMetric = metric }
        let key = ObjectIdentifier(node)
        if let cached = sortCache[key], cached.count == children.count { return cached }
        let sorted = children.sorted { $0.size(metric) > $1.size(metric) }
        sortCache[key] = sorted
        return sorted
    }

    /// Files directly inside `node`, enumerated on demand and cached (capped to
    /// the largest N so a giant folder can't blow up memory or the row count).
    func filesIn(_ node: FSNode) -> [FileItem] {
        // VM scans enumerate over SSH; we don't re-shell per expanded folder.
        guard isHostScan else { return [] }
        let key = ObjectIdentifier(node)
        let count = node.directFileCount
        // Valid as long as the folder's file count is unchanged — true across the
        // 10 Hz refresh during a scan (a folder's files are set once, atomically)
        // and forever after it.
        if let cached = fileCache[key], cached.count == count { return cached.items }

        var items: [FileItem] = []
        if count > 0, let dirPath = path(for: node) {
            let fd = open(dirPath, O_RDONLY | O_DIRECTORY)
            if fd >= 0 {
                let bufSize = 64 * 1024
                let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
                enumerateDirectory(fd: fd, buffer: buf, bufferSize: bufSize) { entry in
                    guard !entry.isDirectory else { return }
                    let name = String(decoding: UnsafeRawBufferPointer(start: entry.name, count: entry.nameLength), as: UTF8.self)
                    items.append(FileItem(name: name, logical: entry.logicalSize, physical: entry.physicalSize))
                }
                buf.deallocate()
                close(fd)
            }
        }
        if items.count > Self.maxFilesPerFolder {
            items.sort { $0.physical > $1.physical }
            items.removeLast(items.count - Self.maxFilesPerFolder)
        }
        fileCache[key] = FileListing(count: count, items: items)
        return items
    }

    /// Full filesystem path of a node, rebuilt from the nearest seed path.
    func path(for node: FSNode) -> String? {
        var components: [String] = []
        var cur: FSNode? = node
        while let n = cur {
            if let base = nodePaths[ObjectIdentifier(n)] {
                var p = base
                for c in components.reversed() {
                    p = (p == "/" ? "/" : p + "/") + c
                }
                return p
            }
            components.append(n.name)
            cur = n.parent
        }
        return nil
    }

    func path(forFile file: FileItem, parent: FSNode) -> String? {
        guard let base = path(for: parent) else { return nil }
        return (base == "/" ? "/" : base + "/") + file.name
    }

    /// Visible outline rows (root + descendants of expanded nodes), with each
    /// expanded folder's files mixed in, biggest-first. O(visible), not O(tree).
    func visibleRows() -> [OutlineRow] {
        guard let root else { return [] }

        // Search mode: show only the pruned path tree (matches + ancestors),
        // fully expanded, directories only.
        if isSearching {
            var out: [OutlineRow] = []
            func walk(_ node: FSNode, depth: Int, siblingMax: Int64) {
                guard searchPath.contains(ObjectIdentifier(node)) else { return }
                let kids = sortedChildren(node).filter { searchPath.contains(ObjectIdentifier($0)) }
                out.append(OutlineRow(
                    kind: .directory(node), depth: depth, siblingMax: siblingMax,
                    isExpandable: false, isExpanded: !kids.isEmpty, id: .dir(ObjectIdentifier(node))))
                let childMax = max(kids.first?.size(metric) ?? 1, 1)
                for kid in kids { walk(kid, depth: depth + 1, siblingMax: childMax) }
            }
            walk(root, depth: 0, siblingMax: max(root.size(metric), 1))
            return out
        }

        var out: [OutlineRow] = []
        out.reserveCapacity(256)

        func walk(_ node: FSNode, depth: Int, siblingMax: Int64) {
            let isOpen = expanded.contains(node)
            let hasContent = node.childCount > 0 || node.directFileCount > 0
            out.append(OutlineRow(
                kind: .directory(node),
                depth: depth,
                siblingMax: siblingMax,
                isExpandable: node.isDirectory && hasContent,
                isExpanded: isOpen,
                id: .dir(ObjectIdentifier(node))
            ))
            guard isOpen else { return }

            let kids = sortedChildren(node)
            let files = filesIn(node).sorted { $0.size(metric) > $1.size(metric) }
            let childMax = max(kids.first?.size(metric) ?? 0, files.first?.size(metric) ?? 0, 1)

            // Merge folders + files by size, biggest first.
            var di = 0, fi = 0
            while di < kids.count || fi < files.count {
                let dSize = di < kids.count ? kids[di].size(metric) : -1
                let fSize = fi < files.count ? files[fi].size(metric) : -1
                if dSize >= fSize {
                    walk(kids[di], depth: depth + 1, siblingMax: childMax)
                    di += 1
                } else {
                    let f = files[fi]
                    out.append(OutlineRow(
                        kind: .file(f, parent: node),
                        depth: depth + 1,
                        siblingMax: childMax,
                        isExpandable: false,
                        isExpanded: false,
                        id: .file(ObjectIdentifier(node), f.name)
                    ))
                    fi += 1
                }
            }
        }
        walk(root, depth: 0, siblingMax: max(root.size(metric), 1))
        return out
    }

    func expandAncestors(of node: FSNode) {
        var parent = node.parent
        while let cur = parent {
            expanded.insert(cur)
            parent = cur.parent
        }
    }

    /// Select a node coming from the treemap; expand its ancestors and scroll it
    /// into view in the outline.
    func reveal(_ node: FSNode) {
        expandAncestors(of: node)
        selection = node
        selectedRowID = .dir(ObjectIdentifier(node))
        revealTarget = node
    }

    // MARK: File operations (context menu)

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openItem(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Rows whose on-disk removal is in flight (the list dims them meanwhile).
    private(set) var deletingRows: Set<RowID> = []
    func isDeleting(_ id: RowID) -> Bool { deletingRows.contains(id) }

    /// Trash or delete a directory. The disk I/O runs off the main thread (a big
    /// `node_modules` no longer beach-balls the UI); the tree/aggregate updates
    /// are applied back on the main actor once it succeeds.
    @discardableResult
    func remove(directory node: FSNode, permanently: Bool) async -> Bool {
        guard node.parent != nil, let path = path(for: node) else { return false }
        let rowID = RowID.dir(ObjectIdentifier(node))
        deletingRows.insert(rowID)
        defer { deletingRows.remove(rowID) }
        guard await Self.diskRemove(path: path, permanently: permanently) else { return false }
        applyDirectoryRemoval(node)
        return true
    }

    private func applyDirectoryRemoval(_ node: FSNode) {
        let logical = node.aggLogical.load(ordering: .relaxed)
        let physical = node.aggPhysical.load(ordering: .relaxed)
        let count = node.fileCount.load(ordering: .relaxed)
        var p = node.parent
        while let a = p {
            a.aggLogical.wrappingAdd(-logical, ordering: .relaxed)
            a.aggPhysical.wrappingAdd(-physical, ordering: .relaxed)
            a.fileCount.wrappingAdd(-count, ordering: .relaxed)
            p = a.parent
        }

        // Lift any navigation state that points into the subtree we're about to
        // free onto the surviving parent, and drop expanded/reveal references to
        // it. Must run *before* detaching, while the parent chain is intact — this
        // is what prevents the use-after-free through dangling `parent` pointers.
        let survivor = node.parent
        if let z = zoomRoot, z === node || Self.isDescendant(z, of: node) { zoomRoot = survivor }
        if let s = selection, s === node || Self.isDescendant(s, of: node) {
            selection = survivor
            selectedRowID = survivor.map { .dir(ObjectIdentifier($0)) }
        }
        if let r = revealTarget, r === node || Self.isDescendant(r, of: node) { revealTarget = nil }
        expanded = expanded.filter { $0 !== node && !Self.isDescendant($0, of: node) }

        // Keep the "folders" stat honest (A7): drop the whole deleted subtree.
        dirCount = max(0, dirCount - Self.subtreeDirCount(node))

        node.parent?.removeChild(node)
        sortCache.removeAll(); fileCache.removeAll()
        refreshTotals()
        bump()
    }

    private static func subtreeDirCount(_ node: FSNode) -> Int64 {
        var total: Int64 = node.isDirectory ? 1 : 0
        for child in node.children { total += subtreeDirCount(child) }
        return total
    }

    /// Whether `node` lies strictly below `ancestor` in the tree.
    private static func isDescendant(_ node: FSNode, of ancestor: FSNode) -> Bool {
        var cur = node.parent
        while let n = cur {
            if n === ancestor { return true }
            cur = n.parent
        }
        return false
    }

    @discardableResult
    func remove(file: FileItem, parent: FSNode, permanently: Bool) async -> Bool {
        guard let path = path(forFile: file, parent: parent) else { return false }
        let rowID = RowID.file(ObjectIdentifier(parent), file.name)
        deletingRows.insert(rowID)
        defer { deletingRows.remove(rowID) }
        guard await Self.diskRemove(path: path, permanently: permanently) else { return false }

        parent.adjustDirectFiles(logical: -file.logical, physical: -file.physical, count: -1)
        var p: FSNode? = parent
        while let a = p {
            a.aggLogical.wrappingAdd(-file.logical, ordering: .relaxed)
            a.aggPhysical.wrappingAdd(-file.physical, ordering: .relaxed)
            a.fileCount.wrappingAdd(-1, ordering: .relaxed)
            p = a.parent
        }
        fileCache[ObjectIdentifier(parent)] = nil // re-enumerate fresh next time
        sortCache.removeAll()
        refreshTotals()
        bump()
        return true
    }

    /// The blocking filesystem call, kept off the main actor.
    private static func diskRemove(path: String, permanently: Bool) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path)
            do {
                if permanently { try FileManager.default.removeItem(at: url) }
                else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                return true
            } catch { return false }
        }.value
    }

    private func refreshTotals() {
        guard let root else { return }
        totalLogical = root.aggLogical.load(ordering: .relaxed)
        totalPhysical = root.aggPhysical.load(ordering: .relaxed)
        fileCount = root.fileCount.load(ordering: .relaxed)
    }

    // MARK: Treemap zoom

    /// Single point that keeps `selection` and the list's `selectedRowID` in
    /// lock-step — the list, breadcrumb and treemap always agree on the node.
    private func setSelection(_ node: FSNode?) {
        selection = node
        selectedRowID = node.map { .dir(ObjectIdentifier($0)) }
    }

    func zoom(into node: FSNode) {
        guard node.isDirectory else { return }
        zoomRoot = node
        setSelection(node)
        bump()
    }

    /// Breadcrumb path: scan root → current zoom root.
    var zoomPath: [FSNode] {
        guard let zoom = zoomRoot else { return [] }
        var path: [FSNode] = []
        var node: FSNode? = zoom
        while let cur = node { path.append(cur); node = cur.parent }
        return path.reversed()
    }

    /// Navigate to a breadcrumb node: zoom the treemap there, select it, and
    /// reveal it in the outline — one click, both panes updated.
    func navigate(to node: FSNode) {
        zoomRoot = node
        reveal(node) // sets selection, selectedRowID, revealTarget, expands ancestors
        bump()
    }

    func zoomOut() {
        if let parent = zoomRoot?.parent {
            zoomRoot = parent
            setSelection(parent)
            revealTarget = parent // scroll the list to the newly focused node
            bump()
        }
    }

    func resetZoom() {
        zoomRoot = root
        setSelection(root)
        bump()
    }

    /// Whether zooming out is possible (drives the breadcrumb button + ⌘↑).
    var canZoomOut: Bool { zoomRoot?.parent != nil }

    // MARK: Timer / refresh

    private func startTimer() {
        // Keep App Nap from throttling the scan when the app loses focus, but still
        // allow the system to sleep on idle (respectful of battery).
        scanActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Disk scan")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(final: false) }
        }
        timer.tolerance = 0.02 // let the OS coalesce wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        if let activity = scanActivity {
            ProcessInfo.processInfo.endActivity(activity)
            scanActivity = nil
        }
    }

    private func refresh(final: Bool) {
        guard let scanner, let root else { return }

        totalLogical = root.aggLogical.load(ordering: .relaxed)
        totalPhysical = root.aggPhysical.load(ordering: .relaxed)
        fileCount = root.fileCount.load(ordering: .relaxed)
        dirCount = scanner.directoryCount
        errorCount = scanner.scanErrorCount

        let now = Date()
        elapsed = now.timeIntervalSince(startTime)
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt >= 0.4 {
            filesPerSecond = Double(fileCount - lastSampleCount) / dt
            lastSampleCount = fileCount
            lastSampleTime = now
        }

        // The extension table is comparatively costly to materialise; do it less
        // often than the size refresh.
        tickIndex += 1
        if final || tickIndex % 4 == 0 {
            extRows = scanner.snapshotExtensions(metric: metric, limit: 250)
        }

        if scanner.isFinished && phase == .scanning {
            if let f = scanner.failure {
                phase = .failed
                failureMessage = f
            } else {
                phase = .finished
            }
            filesPerSecond = 0
            stopTimer()
            extRows = scanner.snapshotExtensions(metric: metric, limit: 250)
        }

        bump()
    }

    private func bump() {
        version &+= 1
    }
}
