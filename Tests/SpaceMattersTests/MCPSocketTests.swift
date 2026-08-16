import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 §3.5 — the attach path. Found the hard way: a socket *file* can
/// outlive the listener that owned it, and the relay treated "refused" as
/// "app not running", so a session told the user their open app was closed.
@Suite struct MCPSocketTests {

    @Test func aSocketFileWhoseOwnerDiedIsRefusedNotAccepted() throws {
        // The production failure: an app instance re-binds the shared path, or
        // one dies without `applicationWillTerminate`, and the file outlives the
        // listener. `fileExists` says yes; only `connect` tells the truth.
        //
        // Built with a real child process rather than by closing a listener in
        // this one. An in-process close is not the state production ever sees —
        // there, the owner is *gone* — and asserting on the instant after
        // `close()` proved to be a coin flip inside a parallel test process,
        // roughly one run in twenty. A process that has exited has no file
        // descriptors left to argue about.
        let nc = "/usr/bin/nc"
        try #require(FileManager.default.isExecutableFile(atPath: nc),
                     "netcat is part of macOS; without it this state cannot be built")
        let path = NSTemporaryDirectory() + "sm-owner-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }

        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: nc)
        listener.arguments = ["-lU", path]
        try listener.run()
        defer { if listener.isRunning { listener.terminate() } }

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: path) && Date() < deadline {
            usleep(20_000)
        }
        try #require(FileManager.default.fileExists(atPath: path), "the listener never bound")

        let live = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(live) }
        #expect(MCPSocketServer.connectSocket(live, to: path) == 0, "a live listener must accept")

        // Kill the owner and *wait for it*, so there is no window to race: once
        // the process is reaped its descriptors are gone.
        kill(listener.processIdentifier, SIGKILL)
        listener.waitUntilExit()

        #expect(FileManager.default.fileExists(atPath: path), "the file must outlive its owner")
        let orphan = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(orphan) }
        #expect(MCPSocketServer.connectSocket(orphan, to: path) != 0)
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
