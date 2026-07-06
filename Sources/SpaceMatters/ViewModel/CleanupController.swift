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
    }

    struct Row: Identifiable {
        let item: Cleanable
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

    private let catalog: [Cleanable]
    private let allowedRoot: String
    private var loadID = 0 // invalidates in-flight sizing (same pattern as Kubernetes mode)

    /// `catalog`/`allowedRoot` are injectable so tests can run against fixtures;
    /// the app uses the built-in catalog fenced to the user's home.
    init(catalog: [Cleanable] = CleanupEngine.catalog(),
         allowedRoot: String = NSHomeDirectory()) {
        self.catalog = catalog
        self.allowedRoot = allowedRoot
    }

    func load() {
        loadID += 1
        let id = loadID
        lastFreed = 0
        lastFailures = 0
        let detected = CleanupEngine.detect(catalog)
        // Keep existing selections across a refresh; drop ones that vanished.
        let previouslySelected = Set(rows.filter(\.selected).map(\.id))
        rows = detected.map { Row(item: $0, selected: previouslySelected.contains($0.id)) }
        state = rows.isEmpty ? .ready : .sizing
        for item in detected {
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
    func stop() { loadID += 1 }

    func toggle(_ id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[idx].selected.toggle()
    }

    // MARK: Select all (tri-state)

    enum SelectAllState { case none, some, all }

    /// Select-all checkbox state over the *selectable* rows (denied/pending
    /// rows have no trustworthy size and never count).
    var selectAllState: SelectAllState {
        let selectable = rows.filter(\.size.isSelectable)
        let selected = selectable.filter(\.selected).count
        if selected == 0 { return .none }
        return selected == selectable.count ? .all : .some
    }

    /// Standard macOS cycle: all → none; none or mixed → all.
    func toggleAll() {
        let target = selectAllState != .all
        for idx in rows.indices {
            rows[idx].selected = target && rows[idx].size.isSelectable
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
    /// are measured, not assumed. Only runs from `.ready` — never mid-sizing.
    func cleanSelected() async {
        guard state == .ready, !selectedRows.isEmpty else { return }
        state = .cleaning
        let before = totalSelected
        let targets = selectedRows.map(\.item)
        let root = allowedRoot

        var failures = 0
        for item in targets {
            let result = await Task.detached(priority: .userInitiated) {
                CleanupEngine.clean(item, allowedRoot: root)
            }.value
            failures += result.failed + result.refused
            let measure = await Task.detached(priority: .userInitiated) {
                CleanupEngine.size(of: item)
            }.value
            apply(measure, to: item.id)
        }

        lastFailures = failures
        lastFreed = max(0, before - totalSelected)
        for idx in rows.indices { rows[idx].selected = false }
        state = .ready
    }

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
