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

    /// Called on every scan completion. Starts the listener the first time —
    /// and **re-binds a listener that has become unreachable**, which is the one
    /// failure that looks fine from the inside: another instance can unlink and
    /// re-bind the shared path out from under us, leaving this process holding a
    /// socket no client can reach while the file sits there looking healthy. A
    /// session that hits that falls back to re-scanning and reports the app as
    /// not running, so it is worth one `connect()` per scan to rule out.
    func startIfNeeded(controller: ScanController) {
        if server != nil {
            guard !MCPSocketServer.isReachable() else { return }
            NSLog("[SpaceMatters] MCP socket unreachable — rebinding")
            server?.stop()
            server = nil
        }
        let server = MCPSocketServer(source: LiveScanSource(controller: controller))
        server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
