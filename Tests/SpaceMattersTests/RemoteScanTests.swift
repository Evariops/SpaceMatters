import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-06: the SSH backend is `CommandScanner` fed the right `find` command.
/// These lock the command construction and the streamed-`find` parser it relies
/// on (exercised locally via `printf`, no network needed).
@Suite struct RemoteScanTests {

    @Test func sshTargetBuildsFindCommand() {
        let t = SSHTarget(user: "bob", host: "example.com", port: 2222,
                          path: "/data", identityFile: "/home/bob/.ssh/id", useSudo: true)
        let cmd = t.command()

        #expect(cmd.executable == "/usr/bin/ssh")
        #expect(cmd.rootPath == "/data")
        #expect(cmd.arguments.contains("bob@example.com"))
        #expect(cmd.arguments.contains("-p") && cmd.arguments.contains("2222"))
        #expect(cmd.arguments.contains("-i") && cmd.arguments.contains("/home/bob/.ssh/id"))
        #expect(cmd.arguments.contains("BatchMode=yes"))
        let remote = cmd.arguments.last ?? ""
        #expect(remote.contains("find '/data' -xdev -printf"))
        #expect(remote.hasPrefix("sudo "))
        #expect(t.label == "bob@example.com:/data")
    }

    @Test func hostOnlyTargetOmitsUserAndOptionals() {
        let cmd = SSHTarget(user: "", host: "server", port: nil, path: "/", identityFile: nil).command()
        #expect(cmd.arguments.contains("server"))
        #expect(!cmd.arguments.contains("-p"))
        #expect(!cmd.arguments.contains("-i"))
        #expect(!(cmd.arguments.last ?? "").hasPrefix("sudo "))
    }

    /// Feed `CommandScanner` a `find`-shaped stream from a local `printf` (the same
    /// NUL-framed records a remote GNU find emits) and check the tree it builds.
    @Test func commandScannerParsesFindStream() {
        let root = FSNode(name: "root", parent: nil)
        // <type>\t<blocks>\t<bytes>\t<path>\0 ; blocks are 512-byte units.
        let fmt = [
            "d\\t0\\t0\\t/root\\000",
            "d\\t0\\t0\\t/root/sub\\000",
            "f\\t8\\t4000\\t/root/sub/a.dat\\000",
            "f\\t2\\t900\\t/root/b.txt\\000",
        ].joined()
        let scanner = CommandScanner(
            root: root, rootPath: "/root",
            executable: "/bin/sh", arguments: ["-c", "printf '\(fmt)'"],
            source: .remote("test-host"))
        scanner.start()
        let deadline = Date().addingTimeInterval(5)
        while !scanner.isFinished && Date() < deadline { usleep(3_000) }

        #expect(scanner.isFinished)
        #expect(scanner.failure == nil)
        #expect(scanner.source == .remote("test-host"))
        #expect(scanner.source.isReadOnly)
        #expect(root.fileCount.load(ordering: .relaxed) == 2)
        #expect(root.aggPhysical.load(ordering: .relaxed) == 8 * 512 + 2 * 512) // 5120
        #expect(root.aggLogical.load(ordering: .relaxed) == 4000 + 900)         // 4900
        #expect(scanner.directoryCount == 2)                                     // root + sub

        let exts = Set(scanner.snapshotExtensions(metric: .physical, limit: 10).map(\.name))
        #expect(exts.contains(".dat") && exts.contains(".txt"))
    }
}
