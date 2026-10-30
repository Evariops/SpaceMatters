import Foundation

/// The real [TUIHost](x-source-tag://TUIHost): the terminal UI driving the very
/// same controllers as the window.
///
/// `--tui` deliberately does not reimplement scanning, deleting or the cleanup
/// pass. It borrows `ScanController` and `CleanupController` whole, so a fix or
/// a guard added for the GUI holds in the terminal too — the alternative, a
/// second implementation of tree surgery, is how the two views would quietly
/// drift apart on the one operation that cannot be taken back.
///
/// Those controllers are `@MainActor`. The frame loop therefore runs on a
/// thread of its own while the main thread runs its run loop (see
/// [TUI](x-source-tag://TUI)): every call here hops onto the main actor, and
/// the long ones (delete, clean, probe) run as a *job* — started, named in the
/// header, and collected when it lands, so the list keeps drawing and the
/// terminal keeps answering keys while a 30 GiB folder goes to the Trash.
final class AppTUIHost: TUIHost {

    private let scan: ScanController
    private let cleanupController: CleanupController

    /// Job label and pending note, written by the main actor and read by the
    /// frame loop — the only two fields crossing threads, hence the lock.
    private let lock = NSLock()
    private var jobLabel: String?
    private var note: String?
    private var sourcesValue = TUISources()
    private var tables: [String: TUITable] = [:]
    private var tablesInFlight: Set<String> = []
    /// Where a terminal deletion is recorded. Injectable, like the cleanup
    /// controller's.
    private let journal: (CleanupJournal.Entry) -> Void

    init(scan: ScanController, cleanup: CleanupController,
         journal: @escaping (CleanupJournal.Entry) -> Void = { CleanupJournal.append($0) }) {
        self.scan = scan
        self.cleanupController = cleanup
        self.journal = journal
    }

    // MARK: Sampling

    var status: TUIStatus {
        var status = onMain { [scan] in
            var s = TUIStatus()
            switch scan.phase {
            case .idle: s.phase = .idle
            case .scanning: s.phase = .scanning
            case .finished: s.phase = .ready
            case .cancelled: s.phase = .cancelled
            case .failed: s.phase = .failed
            }
            s.rootName = scan.rootName
            s.rootPath = scan.rootPath
            s.onDisk = scan.totalPhysical
            s.elapsed = scan.elapsed
            s.files = scan.fileCount
            s.folders = scan.dirCount
            s.skipped = scan.errorCount
            s.types = scan.extRows
            s.isHostScan = scan.isHostScan
            s.canDelete = scan.isHostScan && scan.phase != .scanning
            s.failure = scan.failureMessage
            return s
        }
        lock.lock()
        status.busy = jobLabel
        lock.unlock()
        // A job is tree surgery as often as not; nothing else may start one
        // while it runs.
        if status.busy != nil { status.canDelete = false }
        return status
    }

    var root: FSNode? { onMain { [scan] in scan.root } }

    var sources: TUISources {
        lock.lock(); defer { lock.unlock() }
        return sourcesValue
    }

    var cleanup: TUICleanupState {
        onMain { [cleanupController] in
            var state = TUICleanupState()
            switch cleanupController.state {
            case .idle: state.phase = .idle
            case .sizing: state.phase = .sizing
            case .ready: state.phase = .ready
            case .cleaning: state.phase = .cleaning
            }
            state.rows = cleanupController.rows.map { row in
                let size: TUICleanupRow.Size
                switch row.size {
                case .searching: size = .searching
                case .pending: size = .pending
                case .sized(let bytes): size = .sized(bytes)
                case .denied: size = .denied
                case .blocked(let reason): size = .blocked(reason)
                }
                return TUICleanupRow(id: row.id, name: row.item.name, category: row.item.category,
                                     note: row.item.note, nativeLabel: row.nativeLabel,
                                     regenerable: row.item.regenerable, size: size,
                                     selected: row.selected)
            }
            state.lastFreed = cleanupController.lastFreed
            state.lastFailures = cleanupController.lastFailures
            state.lastRefused = cleanupController.lastRefused
            state.issues = cleanupController.lastNativeIssues
            return state
        }
    }

    func takeNote() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { note = nil }
        return note
    }

    // MARK: Scans

    func reloadSources() {
        startJob("Looking for disks, machines and clusters…") { [weak self] in
            // Every probe shells out; off the main actor, as the splash does.
            let found = await Task.detached(priority: .userInitiated) { () -> TUISources in
                var s = TUISources()
                s.volumes = Volume.mounted()
                s.machines = VMProbe.detect()
                s.contexts = K8sProbe.contexts()
                s.engines = ContainerProbe.detect()
                s.loaded = true
                return s
            }.value
            self?.withLock { $0.sourcesValue = found }
            return nil
        }
    }

    func start(_ source: TUISource) {
        switch source {
        case .volume(let volume):
            onMain { [scan] in scan.scan(volumes: [volume]) }
        case .path(let path):
            onMain { [scan] in scan.scan(url: URL(fileURLWithPath: path)) }
        case .vm(let machine, let scope):
            onMain { [scan] in scan.scanVM(machine: machine, scope: scope) }
        case .cleanup:
            loadCleanup()
        case .kubernetes(let context):
            loadTable(.kubernetes(context: context))
        case .containers(let id):
            loadTable(.containers(engineID: id))
        }
    }

    func goHome() { onMain { [scan] in scan.goHome() } }
    func rescanAll() { onMain { [scan] in scan.rescan() } }
    func cancelScan() { onMain { [scan] in scan.cancel() } }

    func rescan(_ node: FSNode) {
        let name = node.name
        job("Re-reading \(name)…") { [scan] in
            let ok = await scan.invalidate(subtree: node)
            return ok ? "Re-read \(name) from disk" : "Could not re-read \(name)"
        }
    }

    func files(in node: FSNode) -> [TUIFile] {
        onMain { [scan] in
            scan.filesIn(node).map {
                TUIFile(name: $0.name, bytes: $0.physical, apparent: $0.logical, compressed: $0.compressed)
            }
        }
    }

    func path(of node: FSNode) -> String? { onMain { [scan] in scan.path(for: node) } }

    // MARK: Destructive

    /// Every terminal deletion goes to `cleanup.jsonl`, like a cleanup pass
    /// does: a permanent delete typed in a terminal is the one that most
    /// deserves a trail.
    func delete(_ target: TUITarget, permanently: Bool) {
        let verb = permanently ? "Deleting" : "Moving"
        let done = permanently ? "Deleted" : "Moved to Trash"
        let size = Format.bytes(target.bytes)
        let name = target.name
        job("\(verb) \(name)…") { [scan, journal] in
            // Resolved before the removal detaches the node.
            let path: String?
            switch target {
            case .folder(let node): path = scan.path(for: node)
            case .file(let file, let parent): path = scan.path(for: parent).map { ($0 == "/" ? "" : $0) + "/" + file.name }
            }
            let ok: Bool
            switch target {
            case .folder(let node):
                ok = await scan.remove(directory: node, permanently: permanently)
            case .file(let file, let parent):
                let item = ScanController.FileItem(name: file.name, logical: file.apparent,
                                                   physical: file.bytes, compressed: file.compressed)
                ok = await scan.remove(file: item, parent: parent, permanently: permanently)
            }
            var entry = CleanupJournal.Entry(targetID: permanently ? "terminal-delete" : "terminal-trash",
                                             engine: permanently ? "unlink" : "trash",
                                             paths: path.map { [$0] } ?? [name], bytesBefore: target.bytes)
            if ok { entry.removed = 1 } else { entry.failed = 1 }
            journal(entry)
            return ok ? "\(done) — \(name) (\(size))"
                      : "Could not remove \(name) — it may be locked, or in use"
        }
    }

    func copyBriefing() {
        let ok = onMain { [scan] in scan.copyLLMBriefing() }
        withLock { $0.note = ok ? "Briefing copied — paste it into any assistant" : "Nothing to copy yet" }
    }

    func reveal(_ path: String) {
        onMain { [scan] in scan.revealInFinder(path) }
        withLock { $0.note = "Revealed in Finder" }
    }

    func open(_ path: String) {
        onMain { [scan] in scan.openItem(path) }
    }

    // MARK: Cleanup

    func loadCleanup() { onMain { [cleanupController] in cleanupController.load() } }
    func toggleCleanup(_ id: String) { onMain { [cleanupController] in cleanupController.toggle(id) } }
    func toggleAllCleanup() { onMain { [cleanupController] in cleanupController.toggleAll() } }

    func cleanSelected() {
        let state = cleanup
        let count = state.selected.count
        guard count > 0 else { return }
        let expected = Format.bytes(state.totalSelected)
        startJob("Emptying \(count) target\(count == 1 ? "" : "s") (\(expected))…") { [cleanupController] in
            await cleanupController.cleanSelected()
            let failures = cleanupController.lastFailures
            var text = "Freed \(Format.bytes(cleanupController.lastFreed))"
            if failures > 0 { text += " · \(failures) item\(failures == 1 ? "" : "s") could not be removed" }
            return text
        }
    }

    // MARK: Tables

    func table(_ kind: TUITableKind) -> TUITable? {
        lock.lock(); defer { lock.unlock() }
        return tables[Self.key(kind)]
    }

    func loadTable(_ kind: TUITableKind) {
        let key = Self.key(kind)
        lock.lock()
        let already = tablesInFlight.contains(key)
        if !already { tablesInFlight.insert(key) }
        lock.unlock()
        guard !already else { return }

        let started = job(kind.loadingLabel) { [weak self] in
            let table = await Task.detached(priority: .userInitiated) { TUITableBuilder.build(kind) }.value
            self?.withLock {
                $0.tables[key] = table
                $0.tablesInFlight.remove(key)
            }
            return nil
        }
        // Not started: the key must not stay marked in flight, or this table
        // could never load again this session.
        if !started {
            withLock {
                $0.tablesInFlight.remove(key)
                $0.note = "Something is already running — press r once it is done"
            }
        }
    }

    private static func key(_ kind: TUITableKind) -> String {
        switch kind {
        case .kubernetes(let context): return "k8s:" + context
        case .containers(let id): return "containers:" + id
        }
    }

    // MARK: Jobs

    /// Run one long operation off the frame path. Only one at a time: these are
    /// tree surgery, disk walks and vendor commands — overlapping them is how a
    /// second `remove` lands on the tree the first one is rewriting.
    ///
    /// Returns `false` when another job holds the slot and this one did not
    /// start.
    @discardableResult
    private func job(_ label: String, _ body: @escaping @MainActor () async -> String?) -> Bool {
        lock.lock()
        guard jobLabel == nil else { lock.unlock(); return false }
        jobLabel = label
        lock.unlock()
        Task { @MainActor [weak self] in
            let outcome = await body()
            self?.withLock {
                $0.jobLabel = nil
                if let outcome { $0.note = outcome }
            }
        }
        return true
    }

    /// A job the user asked for by name: when the slot is taken, say so rather
    /// than drop it.
    private func startJob(_ label: String, _ body: @escaping @MainActor () async -> String?) {
        if !job(label, body) {
            withLock { $0.note = "Something is already running — try again once it is done" }
        }
    }

    private func withLock(_ body: (AppTUIHost) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(self)
    }

    /// Read or drive the controllers where they live. The frame loop owns its
    /// own thread, so blocking it here never stalls the main actor it waits on.
    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}

private extension TUITableKind {
    var loadingLabel: String {
        switch self {
        case .kubernetes(let context): return "Querying \(context)…"
        case .containers: return "Querying the container engine…"
        }
    }
}

/// Turns the non-filesystem sources into the terminal's one table shape. Runs
/// off the main actor — every call here shells out to `kubectl` or `podman`.
enum TUITableBuilder {

    static func build(_ kind: TUITableKind) -> TUITable {
        switch kind {
        case .kubernetes(let context): return kubernetes(context: context)
        case .containers(let id): return containers(engineID: id)
        }
    }

    private static func kubernetes(context: String) -> TUITable {
        var pvcs = K8sQueries.pvcs(context: context)
        var usage: [String: Int64] = [:]
        for node in K8sQueries.nodeNames(context: context) {
            for (key, value) in K8sQueries.nodeUsage(context: context, node: node) { usage[key] = value }
        }
        pvcs = pvcs.map { pvc in
            var copy = pvc
            if let used = usage[pvc.id] { copy.used = used }
            return copy
        }
        pvcs.sort { $0.capacity > $1.capacity }

        let capacity = pvcs.reduce(0) { $0 + $1.capacity }
        let used = pvcs.compactMap(\.used).reduce(0, +)
        var table = TUITable()
        table.title = "Kubernetes — \(context)"
        table.subtitle = "\(pvcs.count) PVCs · \(Format.bytes(capacity)) provisioned · \(Format.bytes(used)) used"
        table.columns = [
            .init(title: "capacity", width: 10, alignRight: true),
            .init(title: "used", width: 10, alignRight: true, priority: 1),
            .init(title: "class", width: 16, priority: 3),
            .init(title: "phase", width: 9, priority: 2),
            .init(title: "namespace/name", width: 0),
        ]
        table.rows = pvcs.map { pvc in
            TUITable.Row(
                cells: [Format.bytes(pvc.capacity),
                        pvc.used.map(Format.bytes) ?? "—",
                        pvc.storageClass,
                        pvc.phase,
                        pvc.id],
                fraction: pvc.usageFraction,
                dim: pvc.phase != "Bound")
        }
        let pvs = K8sQueries.pvs(context: context).filter(\.reclaimable)
        if !pvs.isEmpty {
            let bytes = pvs.reduce(0) { $0 + $1.capacity }
            table.footnote = "\(pvs.count) released/available PVs — \(Format.bytes(bytes)) reclaimable"
        }
        if pvcs.isEmpty { table.footnote = "No PVC in this context, or kubectl could not reach it." }
        return table
    }

    private static func containers(engineID: String) -> TUITable {
        var table = TUITable()
        guard let engine = ContainerProbe.detect().first(where: { $0.id == engineID }) else {
            table.title = "Containers"
            table.footnote = "No reachable container engine."
            return table
        }
        let snapshot = ContainerQueries.fetchAll(engine)
        let reclaimable = snapshot.df.reduce(0) { $0 + $1.reclaimable }
        table.title = "\(engine.displayName) — images, containers and volumes"
        table.subtitle = snapshot.df
            .map { "\($0.type) \(Format.bytes($0.size))" }
            .joined(separator: " · ")
            + (reclaimable > 0 ? " · \(Format.bytes(reclaimable)) reclaimable" : "")
        table.columns = [
            .init(title: "size", width: 10, alignRight: true),
            .init(title: "kind", width: 10, priority: 2),
            .init(title: "in use", width: 7, priority: 1),
            .init(title: "name", width: 0),
        ]

        let biggest = max(snapshot.images.map(\.size).max() ?? 0,
                          snapshot.volumes.map(\.size).max() ?? 0)
        func fraction(_ bytes: Int64) -> Double? { biggest > 0 ? Double(bytes) / Double(biggest) : nil }

        var rows: [TUITable.Row] = []
        for image in snapshot.images.sorted(by: { $0.size > $1.size }) {
            rows.append(.init(cells: [Format.bytes(image.size), image.dangling ? "image ⚠︎" : "image",
                                      image.inUse ? "yes" : "no", image.name],
                              fraction: fraction(image.size), dim: !image.inUse))
        }
        for volume in snapshot.volumes.sorted(by: { $0.size > $1.size }) {
            rows.append(.init(cells: [Format.bytes(volume.size), "volume", volume.inUse ? "yes" : "no", volume.name],
                              fraction: fraction(volume.size), dim: !volume.inUse))
        }
        for container in snapshot.containers.sorted(by: { $0.size > $1.size }) where container.size > 0 {
            rows.append(.init(cells: [Format.bytes(container.size), "container", container.running ? "yes" : "no",
                                      "\(container.name) (\(container.image))"],
                              fraction: fraction(container.size), dim: !container.running))
        }
        table.footnote = "Read-only here — pruning images stays in the app, where it names what it removes."
        return table
    }
}
