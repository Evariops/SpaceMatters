import Testing
import Foundation
@testable import SpaceMatters

/// Pins the pure parsing seams of the external-engine integrations — the values
/// that decide whether a "Reclaim" button appears, what an image's layers say,
/// and what a PVC's live usage is. None of these shell out.
@Suite struct EngineParsingTests {

    // MARK: Container sizes (docker human units → bytes)

    @Test func parseHumanSizeHandlesDockerUnits() {
        #expect(ContainerQueries.parseHumanSize("1.2GB") == 1_200_000_000)
        #expect(ContainerQueries.parseHumanSize("512MB") == 512_000_000)
        #expect(ContainerQueries.parseHumanSize("737kB") == 737_000)
        #expect(ContainerQueries.parseHumanSize("2TB") == 2_000_000_000_000)
        #expect(ContainerQueries.parseHumanSize("0B") == 0)
        #expect(ContainerQueries.parseHumanSize(" 42B ") == 42)
        #expect(ContainerQueries.parseHumanSize("n/a") == 0)
        #expect(ContainerQueries.parseHumanSize("") == 0)
    }

    // MARK: `--format json` output (array vs JSONL)

    @Test func parseJSONArrayAcceptsArrayAndJSONL() {
        let array = ContainerQueries.parseJSONArray(#"[{"Id":"a"},{"Id":"b"}]"#)
        #expect(array?.count == 2)
        #expect(array?.first?["Id"] as? String == "a")

        let jsonl = ContainerQueries.parseJSONArray("{\"Id\":\"a\"}\n{\"Id\":\"b\"}\n")
        #expect(jsonl?.count == 2)
        #expect(jsonl?.last?["Id"] as? String == "b")

        #expect(ContainerQueries.parseJSONArray("not json at all") == nil)
        #expect(ContainerQueries.parseJSONArray("") == nil)
    }

    // MARK: Layer build commands

    @Test func cleanCommandStripsBuildNoise() {
        #expect(ContainerQueries.cleanCommand("|3 A=1 B=2 /bin/sh -c npm ci") == "npm ci")
        #expect(ContainerQueries.cleanCommand("#(nop) COPY . /app") == "COPY . /app")
        #expect(ContainerQueries.cleanCommand("  RUN make  ") == "RUN make")
    }

    // MARK: kubelet stats summary → PVC usage

    @Test func parseNodeUsageMapsPVCRefs() {
        let raw = """
        {"pods":[
          {"volume":[
            {"usedBytes":123456,"pvcRef":{"namespace":"db","name":"data-pg-0"}},
            {"usedBytes":1,"name":"scratch-no-pvc"}
          ]},
          {"volume":[{"usedBytes":"789","pvcRef":{"namespace":"web","name":"cache"}}]}
        ]}
        """
        let usage = K8sQueries.parseNodeUsage(raw)
        #expect(usage["db/data-pg-0"] == 123_456)
        #expect(usage["web/cache"] == 789)
        #expect(usage.count == 2) // the pvcRef-less volume is ignored
        #expect(K8sQueries.parseNodeUsage("{}").isEmpty)
        #expect(K8sQueries.parseNodeUsage("garbage").isEmpty)
    }

    // MARK: Remote find quoting

    @Test func shellQuoteNeutralizesSingleQuotes() {
        #expect(RemoteFind.shellQuote("/plain/path") == "'/plain/path'")
        // A quote in the path must not terminate the quoted string.
        #expect(RemoteFind.shellQuote("/pa'th") == "'/pa'\\''th'")
        let cmd = RemoteFind.command(rootPath: "/it's here")
        #expect(cmd.contains("find '/it'\\''s here' -xdev"))
    }

    /// The host is user input: it must come after `--` so `-oProxyCommand=…`
    /// can never be parsed as an ssh option.
    @Test func sshHostFollowsEndOfOptions() {
        let cmd = SSHTarget(user: "", host: "-oProxyCommand=touch /tmp/pwned", port: nil,
                            path: "/", identityFile: nil).command()
        let args = cmd.arguments
        let dashIdx = try? #require(args.firstIndex(of: "--"))
        let hostIdx = try? #require(args.firstIndex(of: "-oProxyCommand=touch /tmp/pwned"))
        if let dashIdx, let hostIdx { #expect(dashIdx < hostIdx) }
    }
}

/// Behavior of the hardened process plumbing: deadlines must hold even when
/// the direct child spawns its own children or leaves a straggler on the pipe.
@Suite struct ProcessRunnerTests {

    @Test func nonexistentExecutableFailsCleanly() async {
        let r = await ProcessRunner.run("/nonexistent/binary", [], timeout: 5)
        #expect(!r.ok)
        #expect(r.exitCode == -1)
    }

    /// The watchdog must take down the *grandchild* too — killing only the
    /// direct `sh` would leave `sleep` holding the pipe (the old forever-hang).
    @Test func watchdogKillsWholeProcessTree() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "sh -c 'sleep 30'"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.timedOut)
        #expect(elapsed < 10, "deadline must hold despite the grandchild (took \(elapsed)s)")
    }

    /// A backgrounded straggler that inherits the pipe and outlives the child
    /// must only cost the bounded reader wait — never a hang.
    @Test func exitedChildWithStragglerOnPipeReturnsPromptly() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", ["-c", "echo done; sleep 30 & exit 0"], timeout: 20)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.exitCode == 0)
        #expect(!r.timedOut)
        #expect(elapsed < 10, "bounded reader wait must cap the straggler (took \(elapsed)s)")
        #expect(r.stdoutString.contains("done")) // partial output survives
    }
}
