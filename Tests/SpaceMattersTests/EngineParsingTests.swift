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

    // MARK: Image identity

    /// The ladder that turns a wall of `<none>` into something readable. Each
    /// rung is inference presented to the user as an image's name, so each one
    /// is pinned against the shape podman and docker actually emit.
    @Test func identifyResolvesUntaggedImages() {
        // A live tag wins outright.
        let (tagged, taggedOrigin) = ContainerQueries.identify(
            ["Names": ["ghcr.io/n8n-io/n8n:2.33.4"], "History": ["something:old"]])
        #expect(tagged == "ghcr.io/n8n-io/n8n:2.33.4")
        #expect(taggedOrigin == .tagged)

        // Untagged, but History remembers the tag a newer build took.
        let (former, formerOrigin) = ContainerQueries.identify(
            ["Names": [], "History": ["docker.io/harness/runner-local:latest"]])
        #expect(former == "docker.io/harness/runner-local:latest")
        #expect(formerOrigin == .superseded)

        // A buildah scratch name must not be presented as a repository.
        let (tmp, tmpOrigin) = ContainerQueries.identify(
            ["Names": [],
             "History": ["docker.io/library/7c3a32dc6babb20d4dd0388c45182701cbd93830849e957dbb5f8ae109f1ef58-tmp:latest"]])
        #expect(tmp == "build leftover")
        #expect(tmpOrigin == .buildIntermediate)

        // Pulled by digest: the repository is still known.
        let (digest, digestOrigin) = ContainerQueries.identify(
            ["Names": [], "RepoDigests": ["docker.io/library/postgres@sha256:abc"]])
        #expect(digest == "docker.io/library/postgres")
        #expect(digestOrigin == .digest)

        // Labels are the last real identity before giving up.
        let (labelled, labelledOrigin) = ContainerQueries.identify(
            ["Names": [], "Labels": ["org.opencontainers.image.title": "dockerfiles"]])
        #expect(labelled == "dockerfiles")
        #expect(labelledOrigin == .labelled)

        // Nothing known stays honest rather than inventing a name.
        let (none, noneOrigin) = ContainerQueries.identify(["Names": []])
        #expect(none == "<none>")
        #expect(noneOrigin == .anonymous)

        // Pulled by digest and named as such: the hash is not a tag and 71
        // characters of it would crowd out every other column.
        let (byDigest, byDigestOrigin) = ContainerQueries.identify(
            ["Names": ["docker.io/kindest/node@sha256:7416a61b42b1662ca6ca89f02028ac13"]])
        #expect(byDigest == "docker.io/kindest/node")
        #expect(byDigestOrigin == .digest)

        // podman writes "repo:<none>" for an untagged entry — not a real tag.
        let (placeholder, placeholderOrigin) = ContainerQueries.identify(
            ["Names": ["docker.io/library/x:<none>"], "History": ["docker.io/library/x:1.0"]])
        #expect(placeholder == "docker.io/library/x:1.0")
        #expect(placeholderOrigin == .superseded)
    }

    @Test func buildIntermediateNeedsAHexStem() {
        #expect(ContainerQueries.isBuildIntermediate(
            "docker.io/library/7c3a32dc6babb20d4dd0388c45182701cbd93830849e957db-tmp:latest"))
        // A real project could genuinely be called this; only the hex stem
        // marks a buildah scratch name.
        #expect(!ContainerQueries.isBuildIntermediate("docker.io/acme/build-tmp:latest"))
        #expect(!ContainerQueries.isBuildIntermediate("docker.io/acme/app:latest"))
    }

    /// `podman system df -v` is the only source of per-image unique size and
    /// refuses `--format json`, so the table is parsed. CREATED is a human
    /// duration of unpredictable width, which is why the parse reads from both
    /// ends and never by column offset.
    @Test func parsesUniqueSizesFromTheVerboseTable() {
        let output = """
        Images space usage:

        REPOSITORY                        TAG         IMAGE ID      CREATED           SIZE      SHARED SIZE  UNIQUE SIZE  CONTAINERS
        docker.io/library/postgres        17-alpine   5db836939fe3  2 months          293.8MB   8.94MB       284.9MB      1
        mcr.microsoft.com/dotnet/aspnet   10.0        1ba87edc1ba3  About a minute    265.8MB   265.8MB      7.367kB      0
        <none>                            <none>      18a22e769399  3 weeks           265.8MB   265.8MB      6.188kB      0

        Containers space usage:

        CONTAINER ID  IMAGE         COMMAND     LOCAL VOLUMES  SIZE      CREATED     STATUS      NAMES
        abc123456789  postgres:17   postgres    0              1.5MB     2 days      running     db
        """

        let sizes = ContainerQueries.parseUniqueSizes(output)

        #expect(sizes.count == 3)
        #expect(sizes["5db836939fe3"] == 284_900_000)
        // A three-token CREATED must not shift the size columns.
        #expect(sizes["1ba87edc1ba3"] == 7_367)
        #expect(sizes["18a22e769399"] == 6_188)
        // The containers section has an id-shaped first column too; parsing it
        // as an image would attribute a wrong unique size.
        #expect(sizes["abc123456789"] == nil)
    }

    /// The number a row must not print unqualified: an image listed at 265.8 MB
    /// that frees 6 KB when deleted, because every other byte is a layer other
    /// images hold too.
    @Test func imageKnowsWhenItsSizeOverstatesWhatDeletingFrees() {
        let shared = CImage(id: "a", name: "x", size: 265_800_000, inUse: false,
                            created: nil, uniqueSize: 6_188)
        #expect(shared.sharesMostOfItsBytes)

        let standalone = CImage(id: "b", name: "y", size: 293_800_000, inUse: false,
                                created: nil, uniqueSize: 284_900_000)
        #expect(!standalone.sharesMostOfItsBytes)

        // Docker reports no unique size: claim nothing rather than guess.
        let unknown = CImage(id: "c", name: "z", size: 100, inUse: false, created: nil)
        #expect(!unknown.sharesMostOfItsBytes)
    }

    /// A group of rebuilds of one tag is the common case and the trap. Measured
    /// on a real machine, 38 rebuilds of `harness/runner-local:latest` summed to
    /// 42.6 GiB of image size and **0 B** of per-image unique size: every layer
    /// is shared with a sibling. Neither figure is what removing the group
    /// frees, so the group must not offer one — it says the layers are shared
    /// and points at the engine's own reclaimable instead.
    @Test func aGroupOfRebuildsReportsSharedLayersRatherThanAFakeTotal() {
        let rebuilds = (0..<38).map {
            CImage(id: "img\($0)", name: "harness/runner-local:latest", size: 1_200_000_000,
                   inUse: false, created: nil, origin: $0 == 0 ? .tagged : .superseded,
                   uniqueSize: 8_000)
        }
        let group = CImageGroup(name: "harness/runner-local:latest", images: rebuilds)

        #expect(group.supersededCount == 37)
        #expect(group.unusedCount == 38)
        #expect(group.layersMostlyShared)
        #expect(!group.isSingle)

        // Independent images that each hold their own bytes are not flagged —
        // there the advice "remove as a set" would be wrong.
        let independent = (0..<3).map {
            CImage(id: "sep\($0)", name: "n", size: 1_000_000, inUse: false,
                   created: nil, uniqueSize: 900_000)
        }
        #expect(!CImageGroup(name: "n", images: independent).layersMostlyShared)

        // Without measured unique sizes (docker), no claim is made either way.
        let unmeasured = (0..<3).map {
            CImage(id: "u\($0)", name: "n", size: 1_000_000, inUse: false, created: nil)
        }
        #expect(!CImageGroup(name: "n", images: unmeasured).layersMostlyShared)
    }

    @Test func ageBucketsSeparateRebuildsWithoutPretendingToDateThem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ secondsAgo: Double) -> String {
            Format.age(now.addingTimeInterval(-secondsAgo), now: now)
        }
        #expect(age(600) == "just now")
        #expect(age(5 * 3600) == "5h ago")
        #expect(age(3 * 86_400) == "3d ago")
        #expect(age(21 * 86_400) == "3w ago")
        #expect(age(120 * 86_400) == "4mo ago")
        #expect(age(800 * 86_400) == "2y ago")
        // A clock skew must not produce "-3h ago".
        #expect(age(-3600) == "just now")
    }
}
