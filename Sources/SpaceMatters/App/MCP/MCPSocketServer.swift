import Foundation

/// The running app's side of connected mode — SPEC-14 §3.5.
///
/// A Unix domain socket in the app's support directory. One accept loop on a
/// dedicated thread, one session at a time (an MCP session *is* one client), and
/// the very same `MCPServer` request handling the standalone process runs — only
/// the transport differs.
///
/// The socket is the discovery mechanism too: `--mcp` tries to connect, and its
/// absence is what "the app isn't running" means. Nothing listens on a network
/// interface, so this never leaves the machine.
final class MCPSocketServer: @unchecked Sendable {

    static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/SpaceMatters/mcp.sock"
    }

    private let server: MCPServer
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopping = false

    init(source: any MCPScanSource) {
        self.server = MCPServer(source: source)
    }

    func start() {
        guard listenFD < 0 else { return }
        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // A socket file left behind by a crash would make bind() fail forever.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd); return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return }
        // Owner-only: this hands out a full map of the user's disk.
        chmod(path, 0o600)

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "spacematters.mcp.socket"
        thread.stackSize = 512 * 1024
        thread.start()
        self.thread = thread
    }

    func stop() {
        stopping = true
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(Self.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while !stopping {
            let client = accept(fd, nil, nil)
            if client < 0 { if stopping { return }; continue }
            serve(client)
            close(client)
        }
    }

    private func serve(_ client: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !stopping {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return } // client closed, or the read failed: session over
            pending.append(contentsOf: buffer[0..<n])
            // Line-framed, exactly like stdio — one JSON-RPC message per line.
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                guard let request = JSONRPC.parse(line: line) else { continue }
                guard let response = server.respond(to: request) else { continue }
                guard let data = try? JSONSerialization.data(
                    withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
                var out = data
                out.append(0x0A)
                out.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let wrote = write(client, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                        if wrote <= 0 { return }
                        sent += wrote
                    }
                }
            }
        }
    }
}
