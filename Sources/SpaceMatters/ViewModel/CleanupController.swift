import Foundation
import Observation

/// Drives the Low-Hanging Fruits mode: detects the known-safe cleanup targets,
/// sizes them concurrently (rows fill in live, like a scan), and empties the
/// selected ones. Nothing is pre-selected — cleaning is always an explicit
/// choice, and it is refused while sizing or another clean is in flight.
@MainActor
@Observable
final class CleanupController {
    enum State: Equatable { case idle, sizing, ready, cleaning }

    enum SizeState: Equatable {
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
    private var loadID = 0 // invalidates in-flight sizing (same pattern as Kubernetes mode)
    /// A reload asked for mid-clean is remembered and honoured when the batch
    /// lands, instead of being dropped (or worse, resetting rows under it).
    private var pendingReload = false

    /// Which native cleaner (if any) handles a target, how one is executed, and
    /// which targets are blocked outright on this machine. All injectable:
    /// cleaning is destructive, tests must be able to observe every path
    /// without spawning a real tool or depending on this machine's config.
    private let nativeLookup: @Sendable (String, String) -> NativeCleaner?
    private let nativeRunner: @Sendable (NativeCleaner) async -> ProcessResult
    private let blockedReason: @Sendable (String, String) -> String?
    /// Called on the main actor with one entry per cleaned target — the
    /// forensic trail behind field reports. Injectable so tests can collect.
    private let journal: (CleanupJournal.Entry) -> Void

    /// `catalog`/`allowedRoot` are injectable so tests can run against fixtures;
    /// the app uses the built-in catalog fenced to the user's home.
    init(catalog: [Cleanable] = CleanupEngine.catalog(),
         allowedRoot: String = NSHomeDirectory(),
         nativeLookup: @escaping @Sendable (String, String) -> NativeCleaner? =
            { NativeCleaner.available(for: $0, home: $1) },
         nativeRunner: @escaping @Sendable (NativeCleaner) async -> ProcessResult = { native in
            await ProcessRunner.run(native.binary, native.arguments,
                                    timeout: native.timeout, environment: native.environment)
         },
         blockedReason: @escaping @Sendable (String, String) -> String? = { id, home in
            id == "uv" && CleanupEngine.uvSymlinkMode(home: home)
                ? "uv link-mode is \"symlink\" — cleaning would break your virtualenvs"
                : nil
         },
         journal: @escaping (CleanupJournal.Entry) -> Void = { CleanupJournal.append($0) }) {
        self.catalog = catalog
        self.allowedRoot = allowedRoot
        self.nativeLookup = nativeLookup
        self.nativeRunner = nativeRunner
        self.blockedReason = blockedReason
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
        let detected = CleanupEngine.detect(catalog, allowedRoot: allowedRoot)
        let blocked = Dictionary(uniqueKeysWithValues: detected.compactMap { item in
            blockedReason(item.id, allowedRoot).map { (item.id, $0) }
        })
        // Keep existing selections across a refresh; drop ones that vanished
        // (or got blocked meanwhile).
        let previouslySelected = Set(rows.filter(\.selected).map(\.id))
        rows = detected.map {
            Row(item: $0,
                nativeLabel: nativeLookup($0.id, allowedRoot)?.label,
                size: blocked[$0.id].map(SizeState.blocked) ?? .pending,
                selected: previouslySelected.contains($0.id) && blocked[$0.id] == nil)
        }
        state = rows.contains { $0.size == .pending } ? .sizing : .ready
        for item in detected where blocked[item.id] == nil {
            Task {
                let measure = await Task.detached(priority: .userInitiated) {
                    CleanupEngine.size(of: item)
                }.value
                guard id == self.loadID else { return }
                self.apply(measure, to: item.id)
            }
        }
    }

    func refresh() { load() }
    /// Leaving the mode detaches the UI from in-flight work (sizing results are
    /// dropped, a running batch stops publishing) — it never aborts deletions
    /// the user confirmed.
    func stop() {
        loadID += 1
        pendingReload = false
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

    /// Select-all drives the *cache* rows only. The Trash is the one target
    /// that is user data, not a regenerable cache — it is selected row by row,
    /// never swept up in momentum, and the header checkbox ignores it both ways.
    private func isBulkSelectable(_ row: Row) -> Bool {
        row.size.isSelectable && row.item.id != "trash"
    }

    /// Select-all checkbox state over the bulk-selectable rows (denied/pending/
    /// blocked rows have no trustworthy size and never count; nor does Trash).
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
                    CleanupEngine.clean(item, allowedRoot: root)
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
        case .sized(let bytes): rows[idx].size = .sized(bytes)
        case .denied: rows[idx].size = .denied
        }
        if state == .sizing, !rows.contains(where: { $0.size == .pending }) {
            state = .ready
        }
    }
}

extension CleanupController.SizeState {
    var bytes: Int64 {
        if case .sized(let value) = self { return value }
        return 0
    }

    /// Only measured rows can be selected — a denied or still-sizing row has no
    /// trustworthy size to confirm against.
    var isSelectable: Bool {
        if case .sized = self { return true }
        return false
    }
}
