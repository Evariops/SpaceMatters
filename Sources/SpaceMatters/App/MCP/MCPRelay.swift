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
        if let client = connectToApp() {
            JSONRPC.log("attached to the running SpaceMatters — no re-scan, map tools available")
            defer { close(client) }
            relay(client)
            return 0
        }
        JSONRPC.log("SpaceMatters is not running — scanning standalone (root \(rootPath))")
        return MCPServer(source: DetachedScanSource(rootPath: rootPath)).runStdio()
    }

    private static func connectToApp() -> Int32? {
        let path = MCPSocketServer.socketPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        // A stale socket file from a crashed app refuses the connection; that is
        // indistinguishable from "not running", and both mean: scan standalone.
        guard connected == 0 else { close(fd); return nil }
        return fd
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
