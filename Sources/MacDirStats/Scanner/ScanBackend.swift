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
    func snapshotExtensions(metric: SizeMetric, limit: Int) -> [ExtRow]
}
