import Foundation

/// The `--mcp` process: attach if you can, scan if you can't — SPEC-14 §3.5.
///
/// On startup it tries the running app's socket. Connected, it is a pure relay
/// (stdin line → socket, socket line → stdout) and the session gets the app's
/// live tree with no re-scan plus the map-painting tools. Not connected, it
/// serves a scan of its own. The user never picks: the same command works with
/// or without the app open, which is the only way an MCP entry in a config file
/// can be reliable.
enum MCPRelay {

    static func run(rootPath: String) -> Int32 {
        switch connectToApp() {
        case .connected(let client):
            JSONRPC.log("attached to the running SpaceMatters — no re-scan, map tools available")
            defer { close(client) }
            relay(client)
            return 0
        case .noApp:
            JSONRPC.log("SpaceMatters is not running — scanning standalone (root \(rootPath))")
            return MCPServer(source: DetachedScanSource(rootPath: rootPath),
                             detachedReason: .appNotRunning).runStdio()
        case .unreachable(let code):
            // Distinguished from "not running" on purpose. A model that sees no
            // `annotate` tool concludes the app is closed and tells the user so;
            // when the app is in fact open with a broken socket, that sends them
            // looking in the wrong place entirely.
            JSONRPC.log("a SpaceMatters socket exists but refused the connection (errno \(code)) "
                + "— scanning standalone; rescan in the app to rebind it")
            return MCPServer(source: DetachedScanSource(rootPath: rootPath),
                             detachedReason: .socketUnreachable).runStdio()
        }
    }

    private enum Attachment {
        case connected(Int32)
        case noApp
        case unreachable(Int32)
    }

    private static func connectToApp() -> Attachment {
        let path = MCPSocketServer.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return .noApp }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noApp }
        guard MCPSocketServer.connectSocket(fd, to: path) == 0 else {
            let code = errno
            close(fd)
            return .unreachable(code)
        }
        return .connected(fd)
    }

    /// Pump stdin into the socket on a second thread while the main one pumps
    /// the socket back to stdout. Either side closing ends the session.
    private static func relay(_ client: Int32) {
        let writer = Thread {
            while let line = readLine(strippingNewline: false) {
                var data = Data(line.utf8)
                if !line.hasSuffix("\n") { data.append(0x0A) }
                let ok = data.withUnsafeBytes { raw -> Bool in
                    var sent = 0
                    while sent < raw.count {
                        let wrote = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                        if wrote <= 0 { return false }
                        sent += wrote
                    }
                    return true
                }
                if !ok { break }
            }
            // stdin closed: half-close so the app's read loop sees the end.
            shutdown(client, SHUT_WR)
        }
        writer.name = "spacematters.mcp.relay"
        writer.start()

        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return }
            FileHandle.standardOutput.write(Data(buffer[0..<n]))
        }
    }
}
