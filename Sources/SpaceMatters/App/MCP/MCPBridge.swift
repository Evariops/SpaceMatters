import Foundation

/// Owns the app's MCP socket for the process's lifetime — SPEC-14 §3.5.
///
/// A singleton because the socket path is a single machine-wide rendezvous: two
/// listeners would race for it and the second would silently lose. Started once
/// the app has a scan worth exposing, so a session that attaches always finds a
/// tree rather than an empty controller.
@MainActor
final class MCPBridge {
    static let shared = MCPBridge()

    private var server: MCPSocketServer?

    private init() {}

    /// Idempotent: called from every scan completion, starts at most once.
    func startIfNeeded(controller: ScanController) {
        guard server == nil else { return }
        let server = MCPSocketServer(source: LiveScanSource(controller: controller))
        server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
