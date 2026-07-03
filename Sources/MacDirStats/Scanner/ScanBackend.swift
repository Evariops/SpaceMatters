import Foundation

/// A scan engine that fills an `FSNode` tree live. Two implementations:
/// `DirectoryScanner` (local, getattrlistbulk) and `CommandScanner` (a streamed
/// `find` inside a Podman/Colima VM over SSH). Both update the same tree
/// progressively so the UI reads sizes "au fil de l'eau".
protocol ScanBackend: AnyObject {
    func start()
    func cancel()
    var isFinished: Bool { get }
    var directoryCount: Int64 { get }
    var scanErrorCount: Int64 { get }
    /// A hard failure that made the whole scan meaningless (process couldn't run,
    /// remote `find` missing, exited non-zero with no output). `nil` on success —
    /// per-entry permission errors are counted in `scanErrorCount` instead.
    var failure: String? { get }
    func snapshotExtensions(metric: SizeMetric, limit: Int) -> [ExtRow]
}

extension ScanBackend {
    var failure: String? { nil }
}
