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
    /// The socket path is a single machine-wide rendezvous, so only the GUI may
    /// claim it. Without this gate any process that finishes a scan takes it —
    /// and the test suite does, repeatedly: `swift test` was unlinking a running
    /// app's socket and re-binding it, then exiting, leaving the app holding a
    /// listener nobody could reach. That is the stale-socket failure the relay
    /// now detects, manufactured by our own tests. It also cost the incremental
    /// refresh tests their timing, since every scan completion bound a socket
    /// and started a thread.
    private var isEnabled = false

    private init() {}

    /// Called once by the app at launch. Nothing else should call it: a headless
    /// scan, a test, or a `--briefing` run has no business owning the rendezvous.
    func enable() { isEnabled = true }

    /// Whether this process owns the rendezvous. Read by tests to assert they
    /// never take it from a running app.
    var isRunning: Bool { server != nil }

    /// Called on every scan completion. Starts the listener the first time —
    /// and **re-binds a listener that has become unreachable**, which is the one
    /// failure that looks fine from the inside: another instance can unlink and
    /// re-bind the shared path out from under us, leaving this process holding a
    /// socket no client can reach while the file sits there looking healthy. A
    /// session that hits that falls back to re-scanning and reports the app as
    /// not running, so it is worth one `connect()` per scan to rule out.
    func startIfNeeded(controller: ScanController) {
        guard isEnabled else { return }
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
