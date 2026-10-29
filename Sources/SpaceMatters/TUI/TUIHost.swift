import Foundation

/// A file sitting directly in a folder. Files are not nodes (see `FSNode`), so
/// the terminal lists them the same way the window's outline does: enumerated
/// on demand for the folder you are standing in, never kept for the whole tree.
struct TUIFile: Equatable {
    let name: String
    /// On-disk (allocated) bytes — what deleting frees, as everywhere else.
    let bytes: Int64
    let apparent: Int64

    var divergence: SizeDivergence? {
        SizeDivergence.notable(onDisk: bytes, apparent: apparent,
                               sparseExcess: max(0, apparent - bytes), compressedExcess: 0)
    }
}

/// What an action applies to: a folder in the tree, or one of its files.
enum TUITarget {
    case folder(FSNode)
    case file(TUIFile, in: FSNode)

    var name: String {
        switch self {
        case .folder(let node): return node.name
        case .file(let file, _): return file.name
        }
    }

    var bytes: Int64 {
        switch self {
        case .folder(let node): return node.sizeOnDisk
        case .file(let file, _): return file.bytes
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// Everything the home screen can start. One case per kind of thing worth
/// analysing — the same list the window's splash screen offers.
enum TUISource {
    case volume(Volume)
    case path(String)
    case vm(VMMachine, VMScope)
    case cleanup
    case kubernetes(String)
    case containers(engineID: String)
}

/// What the home screen found to analyse. Gathered by a job (every probe
/// shells out to `podman`/`kubectl`), never on the frame path.
struct TUISources {
    var volumes: [Volume] = []
    var machines: [VMMachine] = []
    var contexts: [K8sContext] = []
    var engines: [ContainerEngine] = []
    var loaded = false
}

/// Scan-wide facts, sampled once per frame.
struct TUIStatus {
    enum Phase { case idle, scanning, ready, cancelled, failed }

    var phase: Phase = .idle
    var rootName = ""
    var rootPath = ""
    var onDisk: Int64 = 0
    var elapsed: TimeInterval = 0
    var files: Int64 = 0
    var folders: Int64 = 0
    var skipped: Int64 = 0
    /// Scan-wide and exact; only read while the types panel is shown.
    var types: [ExtRow] = []
    /// False for VM/SSH scans — their paths are not this machine's paths, so
    /// Trash, Finder and on-demand file listing do not apply.
    var isHostScan = true
    /// Removal is refused while the scanner's workers are still mutating the
    /// tree, and on anything that is not a host scan. The screens ask this
    /// rather than re-deriving the rule.
    var canDelete = false
    var failure: String?
    /// Label of the job currently running ("Emptying 6 targets…"), if any.
    var busy: String?

    var isScanning: Bool { phase == .scanning }
}

/// One Low-Hanging Fruits row, flattened for the terminal.
struct TUICleanupRow: Equatable {
    enum Size: Equatable {
        /// A target discovery is still looking for (see `CleanupController`).
        case searching
        case pending
        case sized(Int64)
        case denied
        case blocked(String)
    }

    let id: String
    let name: String
    let category: String
    let note: String
    /// Set when the vendor's own cleaner runs instead of file removal.
    let nativeLabel: String?
    /// False for the Trash and orphaned editor state: bytes that never come
    /// back. They are picked one by one, never swept up by "select all".
    let regenerable: Bool
    var size: Size
    var selected: Bool

    var bytes: Int64 {
        if case .sized(let value) = size { return value }
        return 0
    }

    /// Same rule as `CleanupController.SizeState.isSelectable`: measured, and
    /// something in it.
    var isSelectable: Bool {
        if case .sized(let value) = size { return value > 0 }
        return false
    }
}

/// The cleanup screen's whole state, as a value.
struct TUICleanupState {
    enum Phase: Equatable { case idle, sizing, ready, cleaning }
    var phase: Phase = .idle
    var rows: [TUICleanupRow] = []
    var lastFreed: Int64 = 0
    var lastFailures = 0
    var lastRefused = 0
    var issues: [String] = []

    var selected: [TUICleanupRow] { rows.filter(\.selected) }
    var totalFound: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    var totalSelected: Int64 { selected.reduce(0) { $0 + $1.bytes } }
}

/// A read-only table the terminal can show for the sources that are not a
/// filesystem tree (Kubernetes volumes, container images).
struct TUITable {
    struct Column {
        let title: String
        let width: Int
        /// Numbers read right-aligned; names and ids read left-aligned.
        var alignRight = false
        /// Dropped first when the terminal is too narrow (low number = kept).
        var priority = 0
    }

    struct Row {
        let cells: [String]
        /// Drives the proportion bar, when the table has one.
        var fraction: Double?
        var dim = false
    }

    var title = ""
    var subtitle = ""
    var columns: [Column] = []
    var rows: [Row] = []
    var footnote: String?
}

enum TUITableKind: Equatable {
    case kubernetes(context: String)
    case containers(engineID: String)
}

/// What a screen asks the app to do with a key it did not answer itself.
///
/// Screens stay pure values by never acting: they return an intent, and
/// [TUIApp](x-source-tag://TUIApp) decides whether it needs a confirmation, a
/// route change or a call into the host.
///
/// - Tag: TUIRequest
enum TUIRequest {
    case none
    /// Leave this screen — back to the home menu, or out of the app from it.
    case back
    case help
    case menu
    case quit

    // Filesystem
    case info(TUITarget)
    case confirmDelete(TUITarget, permanently: Bool)
    case rescan(FSNode)
    case rescanAll
    case cancelScan
    case copyBriefing
    case reveal(TUITarget)
    case open(TUITarget)
    /// Jump the browser to a folder (from a search result).
    case goTo(FSNode)
    case find(FSNode)
    case top(FSNode)
    case aged(FSNode)

    // Home
    case start(TUISource)
    case promptPath
    case reloadSources

    // Cleanup
    case toggle(String)
    case toggleAll
    case confirmClean
    case reloadCleanup

    /// Re-run the query behind a read-only table (Kubernetes, containers).
    case reloadTable
}

/// Everything the terminal UI asks of the app.
///
/// The screens are pure values over this protocol: the real implementation
/// drives the very same controllers the window does (so a feature cannot drift
/// between the two), and tests drive a fake with no disk, no `kubectl` and no
/// Trash behind it.
///
/// Called from the TUI's own thread. Implementations are responsible for
/// hopping to wherever their state lives.
protocol TUIHost: AnyObject {
    var status: TUIStatus { get }
    var root: FSNode? { get }
    var sources: TUISources { get }
    var cleanup: TUICleanupState { get }

    /// A one-line result to show in the footer ("Moved to Trash — 1.2 GiB"),
    /// consumed by the frame that displays it.
    func takeNote() -> String?

    func reloadSources()
    func start(_ source: TUISource)
    /// Leave the analysis and go back to the home screen.
    func goHome()
    func rescanAll()
    /// Re-read one folder from disk (SPEC-02 invalidation).
    func rescan(_ node: FSNode)
    func cancelScan()

    func files(in node: FSNode) -> [TUIFile]
    func path(of node: FSNode) -> String?

    func delete(_ target: TUITarget, permanently: Bool)
    func copyBriefing()
    func reveal(_ path: String)
    func open(_ path: String)

    func loadCleanup()
    func toggleCleanup(_ id: String)
    func toggleAllCleanup()
    func cleanSelected()

    func loadTable(_ kind: TUITableKind)
    func table(_ kind: TUITableKind) -> TUITable?
}
