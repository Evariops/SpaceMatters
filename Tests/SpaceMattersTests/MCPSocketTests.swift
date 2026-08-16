import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 §3.5 — the attach path. Found the hard way: a socket *file* can
/// outlive the listener that owned it, and the relay treated "refused" as
/// "app not running", so a session told the user their open app was closed.
@Suite struct MCPSocketTests {

    /// Binds a throwaway listener and returns its fd + path.
    private func listener() throws -> (fd: Int32, path: String) {
        let path = NSTemporaryDirectory() + "sm-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 4) == 0)
        return (fd, path)
    }

    @Test func connectSucceedsAgainstALiveListener() throws {
        let (server, path) = try listener()
        defer { close(server); unlink(path) }
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(MCPSocketServer.connectSocket(client, to: path) == 0)
    }

    @Test func aFileWithoutAListenerIsRefusedNotAccepted() throws {
        // The exact production failure: the listener dies (another instance
        // re-binds the path, or a crash skips applicationWillTerminate) and the
        // file remains. `fileExists` says yes; only `connect` tells the truth.
        let (server, path) = try listener()
        close(server) // listener gone, file stays
        defer { unlink(path) }
        #expect(FileManager.default.fileExists(atPath: path))
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(MCPSocketServer.connectSocket(client, to: path) != 0)
    }

    @Test func aMissingPathIsRefused() {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(MCPSocketServer.connectSocket(client, to: NSTemporaryDirectory() + "nope.sock") != 0)
    }

    @Test func overlongPathsAreRejectedRatherThanTruncated() {
        // `sun_path` is 104 bytes; a silent truncation would bind or connect to
        // the wrong path entirely.
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(MCPSocketServer.connectSocket(client, to: "/tmp/" + String(repeating: "x", count: 200)) != 0)
    }

    @Test func theUnreachableNoticeDoesNotClaimTheAppIsClosed() {
        // A model that hears "the app isn't running" sends the user looking in
        // the wrong place — the app may be open with a stale socket. This is the
        // sentence that broke a real session; it is now asserted.
        let unreachable = MCPServer.DetachedReason.socketUnreachable.note
        #expect(unreachable.contains("Do not tell the user the app is closed"))
        #expect(unreachable.lowercased().contains("rescan"))

        let closed = MCPServer.DetachedReason.appNotRunning.note
        #expect(closed.contains("not running"))
        #expect(closed != unreachable)
    }
}
