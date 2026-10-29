import Foundation
import Observation

/// Drives the Low-Hanging Fruits mode: detects the known-safe cleanup targets,
/// sizes them one at a time (each walk drives the scanner's whole worker pool,
/// so rows still fill in live — in order rather than all at once), and empties
/// the selected ones. Nothing is pre-selected — cleaning is always an explicit
/// choice, and it is refused while sizing or another clean is in flight.
///
/// Every row the mode can show is on screen from the first frame: targets that
/// discovery is still looking for stand in as `.searching` rows in their final
/// section, and each search swaps its stand-ins for what it found as soon as it
/// lands. Nothing appears or vanishes once the list is up: a target that turns
/// out empty, or a search that finds nothing, stays in place and says so.
@MainActor
@Observable
final class CleanupController {
    enum State: Equatable { case idle, sizing, ready, cleaning }

    enum SizeState: Equatable {
        /// A target discovery may still find — a stand-in, with no paths yet.
        case searching
        case pending
        case sized(Int64)
        /// Exists but unreadable — typically the Trash without Full Disk Access.
        case denied
        /// Cleaning this target on this machine would break things (uv in
        /// `link-mode=symlink`) — never sized, never selectable, reason shown.
        case blocked(String)
    }

    struct Row: Identifiable {
        let item: Cleanable
        /// Set when the vendor's own cleaner will run instead of file removal.
        var nativeLabel: String?
        var size: SizeState = .pending
        var selected = false
        var id: String { item.id }
    }

    private(set) var state: State = .idle
    private(set) var rows: [Row] = []
    /// Bytes freed by the last clean (before/after sizing difference).
    private(set) var lastFreed: Int64 = 0
    /// Children that could not be removed during the last clean (locked files…).
    private(set) var lastFailures = 0
    /// Paths the safety fence refused during the last clean — a bug indicator
    /// (detect and clean disagreeing), surfaced distinctly from plain failures.
    private(set) var lastRefused = 0
    /// Native cleaners that exited non-zero during the last clean ("Homebrew —
    /// brew cleanup: …"). Surfaced as an alert; never retried as file removal —
    /// the failure may be the vendor's lock doing its job.
    private(set) var lastNativeIssues: [String] = []

    private let catalog: [Cleanable]
    private let allowedRoot: String
    /// The temporary folders the stale-temporary-files target is fenced to.
    private let temporaryRoots: [String]
    private var loadID = 0 // invalidates in-flight sizing (same pattern as Kubernetes mode)
    /// A reload asked for mid-clean is remembered and honoured when the batch
    /// lands, instead of being dropped (or worse, resetting rows under it).
    private var pendingReload = false
    /// Searches of the current load that have not landed yet. Sizing the rows
    /// already known can finish long before them, and `.ready` must not be
    /// announced while rows are still on their way — the Clean button becomes
    /// live at `.ready`.
    private var searchesInFlight = 0
    /// The load whose sizing loop is running, if any: one loop per load, so
    /// its walks never overlap — rows that land mid-loop just join its queue.
    private var sizingLoad: Int?

    /// Which native cleaner (if any) handles a target, how one is executed, and
    /// which targets are blocked outright on this machine. All injectable:
    /// cleaning is destructive, tests must be able to observe every path
    /// without spawning a real tool or depending on this machine's config.
    private let nativeLookup: @Sendable (String, String) -> NativeCleaner?
    private let nativeRunner: @Sendable (NativeCleaner) async -> ProcessResult
    /// Takes the whole target, not just its id: the app-liveness rule reads
    /// `ownerBundleID`, so a target declares its own gate instead of every new
    /// app needing a case added here.
    private let blockedReason: @Sendable (Cleanable, String) -> String?
    /// Targets whose paths depend on what is on the disk (build output,
    /// orphaned workspace state, browser profiles, temporary leftovers), as
    /// searches with their stand-ins. Built on the main actor at every load;
    /// the searches themselves run off it. Injectable.
    private let discovery: (String) -> [CleanupDiscovery.Pass]
    /// Called on the main actor with one entry per cleaned target — the
    /// forensic trail behind field reports. Injectable so tests can collect.
    private let journal: (CleanupJournal.Entry) -> Void

    /// `catalog`/`allowedRoot` are injectable so tests can run against fixtures;
    /// the app uses the built-in catalog fenced to the user's home.
    ///
    /// `temporaryRoots` defaults to the account's own temporary folders — but
    /// only when the fence *is* the account's home. They belong to the same
    /// account: a controller fenced to anything else (a test fixture) has none,
    /// rather than reaching for the real `/tmp` behind its fixture's back.
    init(catalog: [Cleanable] = CleanupEngine.catalog(),
         allowedRoot: String = NSHomeDirectory(),
         temporaryRoots: [String]? = nil,
         nativeLookup: @escaping @Sendable (String, String) -> NativeCleaner? =
            { NativeCleaner.available(for: $0, home: $1) },
         nativeRunner: @escaping @Sendable (NativeCleaner) async -> ProcessResult = { native in
            await ProcessRunner.run(native.binary, native.arguments,
                                    timeout: native.timeout, environment: native.environment)
         },
         blockedReason: @escaping @Sendable (Cleanable, String) -> String? = {
            CleanupEngine.blockedReason(for: $0, home: $1)
         },
         discovery: ((String) -> [CleanupDiscovery.Pass])? = nil,
         journal: @escaping (CleanupJournal.Entry) -> Void = { CleanupJournal.append($0) }) {
        let temporaryRoots = temporaryRoots
            ?? (allowedRoot == NSHomeDirectory() ? TemporaryFiles.roots() : [])
        self.catalog = catalog
        self.allowedRoot = allowedRoot
        self.temporaryRoots = temporaryRoots
        self.nativeLookup = nativeLookup
        self.nativeRunner = nativeRunner
        self.blockedReason = blockedReason
        self.discovery = discovery ?? { CleanupDiscovery.passes(home: $0, temporaryRoots: temporaryRoots) }
        self.journal = journal
    }

    func load() {
        // The model guards itself (same philosophy as DeletionGuardTests): a
        // reload during a clean would reset rows/state under the operation —
        // remember the intent and run it once the batch lands.
        guard state != .cleaning else {
            pendingReload = true
            return
        }
        loadID += 1
        let id = loadID
        lastFreed = 0
        lastFailures = 0
        lastRefused = 0
        lastNativeIssues = []
        // Keep existing selections across a refresh; drop ones that vanished
        // (or got blocked meanwhile).
        let previouslySelected = Set(rows.filter(\.selected).map(\.id))
        // The hand-picked catalog is a pure list, so its rows can be shown and
        // sized immediately. Each search walks the disk — seconds, on a
        // developer's home or a long-lived /tmp — so its targets stand in right
        // away, and the search swaps them for what it found the moment it
        // lands: not after the catalog is sized, since a search that finished
        // in a second must not wait behind a 30 GiB build cache.
        let passes = discovery(allowedRoot)
        rows = makeRows(CleanupEngine.detect(catalog, allowedRoot: allowedRoot,
                                             temporaryRoots: temporaryRoots),
                        selected: previouslySelected)
            + passes.flatMap { $0.placeholders.map { Row(item: $0, size: .searching) } }
        state = .sizing
        searchesInFlight = passes.count
        let root = allowedRoot
        let temporaryRoots = self.temporaryRoots
        for pass in passes {
            let standIns = Set(pass.placeholders.map(\.id))
            Task {
                // Readdir-only walks: they cost little next to the sizing
                // walks, so they all run alongside them rather than before.
                let found = await Task.detached(priority: .userInitiated) {
                    CleanupEngine.detect(pass.run(), allowedRoot: root, temporaryRoots: temporaryRoots)
                }.value
                guard id == self.loadID else { return }
                self.join(self.makeRows(found, selected: previouslySelected), replacing: standIns)
                self.searchesInFlight -= 1
                self.sizeRemaining(id: id)
                // The search may have found nothing, or only blocked rows, in
                // which case no `apply` runs to make the transition.
                self.settle()
            }
        }
        sizeRemaining(id: id)
    }

    /// Size the pending rows one at a time, in list order. Each sizing walk
    /// drives the full scanner worker pool, so running the targets
    /// concurrently would multiply threads rather than work. Rows a search adds
    /// while the loop runs simply join its queue; once the loop has run dry,
    /// the next search to land starts it again.
    private func sizeRemaining(id: Int) {
        guard sizingLoad != id else { return }
        sizingLoad = id
        Task {
            while id == loadID, let item = rows.first(where: { $0.size == .pending })?.item {
                let measure = await Task.detached(priority: .userInitiated) {
                    CleanupEngine.size(of: item)
                }.value
                guard id == loadID else { break }
                apply(measure, to: item.id)
            }
            if sizingLoad == id { sizingLoad = nil }
            settle()
        }
    }

    /// Swap each of a search's stand-ins for the row it found, in place. A
    /// stand-in whose target was not found stays too, reading "none found":
    /// nothing on screen moves or vanishes when a search lands.
    private func join(_ found: [Row], replacing standIns: Set<String>) {
        var unplaced = found
        rows = rows.map { row in
            guard standIns.contains(row.id), row.size == .searching else { return row }
            if let match = unplaced.firstIndex(where: { $0.id == row.id }) {
                return unplaced.remove(at: match)
            }
            return Row(item: row.item.placeholder("none found"), size: .sized(0))
        }
        // A target the search found without having stood in for it — only
        // possible when a stand-in hint missed. Late is better than never.
        rows += unplaced
    }

    /// `.ready` once nothing is left to measure and nothing is still to arrive.
    private func settle() {
        guard state == .sizing, searchesInFlight == 0,
              !rows.contains(where: { $0.size == .pending || $0.size == .searching }) else { return }
        state = .ready
    }

    /// Rows for a detected batch, with the blocked reasons resolved and the
    /// pre-refresh selection carried over. Shared by the catalog and the
    /// discovered batch so both get identical treatment.
    private func makeRows(_ items: [Cleanable], selected: Set<String>) -> [Row] {
        items.map { item in
            let blocked = blockedReason(item, allowedRoot)
            return Row(item: item,
                       nativeLabel: nativeLookup(item.id, allowedRoot)?.label,
                       size: blocked.map(SizeState.blocked) ?? .pending,
                       selected: selected.contains(item.id) && blocked == nil)
        }
    }

    func refresh() { load() }
    /// Leaving the mode detaches the UI from in-flight work (sizing results are
    /// dropped, a running batch stops publishing) — it never aborts deletions
    /// the user confirmed.
    func stop() {
        loadID += 1
        pendingReload = false
        searchesInFlight = 0
    }

    /// The model guards itself: a pending/denied/blocked row cannot be selected
    /// however the call arrives, not just because the checkbox is disabled.
    func toggle(_ id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }),
              rows[idx].size.isSelectable else { return }
        rows[idx].selected.toggle()
    }

    // MARK: Select all (tri-state)

    enum SelectAllState { case none, some, all }

    /// Select-all drives the *regenerable* rows only. The Trash and orphaned
    /// editor state are user data whose bytes never come back — they are
    /// selected row by row, never swept up in momentum, and the header checkbox
    /// ignores them both ways.
    private func isBulkSelectable(_ row: Row) -> Bool {
        row.size.isSelectable && row.item.regenerable
    }

    /// Select-all checkbox state over the bulk-selectable rows (denied/pending/
    /// blocked rows have no trustworthy size and never count; nor do the
    /// non-regenerable ones).
    var selectAllState: SelectAllState {
        let selectable = rows.filter(isBulkSelectable)
        let selected = selectable.filter(\.selected).count
        if selected == 0 { return .none }
        return selected == selectable.count ? .all : .some
    }

    /// Standard macOS cycle: all → none; none or mixed → all.
    func toggleAll() {
        let target = selectAllState != .all
        for idx in rows.indices where isBulkSelectable(rows[idx]) {
            rows[idx].selected = target
        }
    }

    // MARK: Derived totals

    var selectedRows: [Row] { rows.filter(\.selected) }

    /// Rows that hold something, or may: empty ones and stand-ins still
    /// searching are on screen but are not locations to clean.
    var locationCount: Int { rows.filter { !$0.size.isEmpty && $0.size != .searching }.count }

    /// Sum of the sized rows (the "found" total in the summary strip).
    var totalFound: Int64 { rows.reduce(0) { $0 + $1.size.bytes } }
    var totalSelected: Int64 { selectedRows.reduce(0) { $0 + $1.size.bytes } }

    var categories: [String] {
        var seen: Set<String> = []
        return rows.map(\.item.category).filter { seen.insert($0).inserted }
    }

    func rows(in category: String) -> [Row] {
        rows.filter { $0.item.category == category }
    }

    // MARK: Cleaning

    /// Empty the selected targets, then re-size them so the freed bytes shown
    /// are measured, not assumed. Only starts from `.ready` — never mid-sizing.
    /// A confirmed batch always runs to completion: leaving the mode detaches
    /// the UI (`loadID` guards the writes), never the deletions, and the
    /// controller always lands back on a terminal state — an abandoned
    /// `.cleaning` would brick the mode (`load()` refuses under it).
    func cleanSelected() async {
        guard state == .ready, !selectedRows.isEmpty else { return }
        state = .cleaning
        let id = loadID
        let before = totalSelected
        let targets = selectedRows.map(\.item)
        let root = allowedRoot
        let temporaryRoots = self.temporaryRoots

        var failures = 0
        var refused = 0
        var issues: [String] = []
        let active = ToolActivity.activeTools(for: Set(targets.map(\.id)))
        for item in targets {
            var entry = CleanupJournal.Entry(
                targetID: item.id, engine: "file", paths: item.paths,
                bytesBefore: rows.first(where: { $0.id == item.id })?.size.bytes ?? 0)
            entry.activeTools = active[item.id]?.sorted() ?? []
            // Availability is resolved at clean time, not load time: the label
            // shown is a promise, the decision here is the truth.
            if let native = nativeLookup(item.id, root) {
                entry.engine = native.label
                let result = await nativeRunner(native)
                if !result.ok {
                    entry.diagnostic = result.diagnostic
                    issues.append("\(item.name) — \(native.label): \(result.diagnostic)")
                }
            } else {
                let result = await Task.detached(priority: .userInitiated) {
                    CleanupEngine.clean(item, allowedRoot: root, temporaryRoots: temporaryRoots)
                }.value
                entry.removed = result.removed
                entry.failed = result.failed
                entry.refused = result.refused
                failures += result.failed
                refused += result.refused
            }
            let measure = await Task.detached(priority: .userInitiated) {
                CleanupEngine.size(of: item)
            }.value
            if case .sized(let bytes) = measure { entry.bytesAfter = bytes }
            journal(entry)
            if id == loadID { apply(measure, to: item.id) } // UI only — the batch continues
        }

        if id == loadID { // results belong to the session that confirmed them
            lastFailures = failures
            lastRefused = refused
            lastNativeIssues = issues
            lastFreed = max(0, before - totalSelected)
            for idx in rows.indices { rows[idx].selected = false }
        }
        state = .ready
        if pendingReload {
            pendingReload = false
            load()
        }
    }

    func dismissNativeIssues() { lastNativeIssues = [] }

    // MARK: Private

    private func apply(_ measure: CleanupEngine.Measure, to id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        switch measure {
        // An empty target stays where it is and says so. Dropping it was
        // tidier on paper, but on screen it is a row vanishing under the
        // pointer — half the list rearranging itself while the user reads it.
        case .sized(let bytes): rows[idx].size = .sized(bytes)
        case .denied: rows[idx].size = .denied
        }
        settle()
    }
}

extension CleanupController.SizeState {
    var bytes: Int64 {
        if case .sized(let value) = self { return value }
        return 0
    }

    /// Only measured rows with something in them can be selected — a denied or
    /// still-sizing row has no trustworthy size to confirm against, and an
    /// empty one has nothing to clean.
    var isSelectable: Bool {
        if case .sized(let bytes) = self { return bytes > 0 }
        return false
    }

    /// Measured, and nothing there — or a search that found nothing.
    var isEmpty: Bool { self == .sized(0) }
}
