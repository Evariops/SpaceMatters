import Foundation

/// The running app's scan, exposed to an MCP session over the socket — SPEC-14 §3.5.
///
/// Connected mode's whole point: **no re-scan at all**, the session sees exactly
/// the tree the user is looking at, and verdicts can be painted back onto the map.
///
/// `@unchecked Sendable` with a `nonisolated(unsafe)` controller: only the handle
/// is taken on the main actor. The tree walk itself then runs on the socket
/// thread over `FSNode`, whose reads are atomic or `gTreeLock`-guarded precisely
/// so a reader outside the UI is safe — that is the same property the live scan
/// relies on. Anything that *mutates* controller state hops back to main.
final class LiveScanSource: MCPScanSource, @unchecked Sendable {

    nonisolated(unsafe) private let controller: ScanController

    init(controller: ScanController) {
        self.controller = controller
    }

    /// Run `body` on the main actor and wait. Safe from the socket thread: the
    /// main actor never blocks waiting on it, so there is no cycle to deadlock.
    private func onMain<T>(_ body: @MainActor (ScanController) throws -> T) rethrows -> T {
        try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { try body(controller) }
        }
    }

    func index() throws -> TreeQuery.Index {
        try onMain { controller in
            guard let root = controller.root else {
                throw MCPScanError(message: "SpaceMatters has no scan loaded. Pick a disk or a "
                    + "folder in the app, or restart this session without the app running to "
                    + "scan standalone.")
            }
            return TreeQuery.Index(root: root, rootPath: controller.rootPath)
        }
    }

    func stats() -> MCPScanStats {
        onMain { controller in
            var stats = MCPScanStats(
                rootPath: controller.rootPath,
                rootName: controller.rootName,
                files: controller.fileCount,
                dirs: controller.dirCount,
                errors: controller.errorCount,
                elapsed: controller.elapsed,
                date: controller.scanDate,
                counting: controller.countingMode,
                hasFullDiskAccess: FullDiskAccess.isGranted,
                isLive: true)
            // A multi-disk scan hangs its volumes under a virtual root with no
            // path of its own, so every path this source produced would be
            // wrong. Say so rather than emit them.
            if controller.rootPath.isEmpty {
                stats.limitation = "This is a multi-disk scan: its roots have no single base "
                    + "path, so paths cannot be resolved. Scan one disk or folder in the app, "
                    + "or run the server standalone."
            }
            if controller.phase == .scanning {
                stats.limitation = (stats.limitation.map { $0 + " " } ?? "")
                    + "The app is still scanning: totals are rising and incomplete."
            }
            return stats
        }
    }

    func exactTypes() -> [ExtRow] {
        onMain { $0.extRows }
    }

    var supportsMap: Bool { true }

    func annotate(path: String, verdict: Verdict, reason: String) throws {
        try onMain { controller in
            guard controller.annotate(path: path, verdict: verdict, reason: reason) != nil else {
                throw MCPScanError(message: "\(path) is not a folder in the current scan, so there "
                    + "is nothing on the map to mark.")
            }
        }
    }

    func focus(path: String) throws {
        try onMain { controller in
            guard let node = controller.node(at: path) else {
                throw MCPScanError(message: "\(path) is not a folder in the current scan.")
            }
            controller.reveal(node)
        }
    }
}
