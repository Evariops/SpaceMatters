import Foundation
import Testing
@testable import SpaceMatters

/// Safety invariants of discovered cleanup targets.
///
/// The hand-picked catalog is safe because a human wrote each path down.
/// Discovery has no such guarantee, so what it *refuses* matters more than what
/// it finds: these tests pin the refusals first, and the marker rule that
/// produces them.
@Suite struct CleanupDiscoveryTests {

    private static func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeDir(_ root: URL, _ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeFile(_ root: URL, _ relative: String, bytes: Int = 2048) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    // MARK: The marker rule

    /// The whole feature in one test: `bin` and `obj` beside a project file are
    /// build output; the same names anywhere else are not, and the difference is
    /// a sibling marker rather than a name the code happens to trust.
    @Test func binIsOnlyOfferedNextToAProjectFile() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/App.csproj")
        _ = try Self.makeDir(root, "App/bin/Debug")
        _ = try Self.makeDir(root, "App/obj/Debug")
        // Same names, no project file: a plain output directory of some other
        // toolchain. Nothing here explains deleting it.
        _ = try Self.makeDir(root, "Tool/bin")
        _ = try Self.makeDir(root, "Tool/obj")

        let hits = Set(CleanupDiscovery.walkForArtifacts(home: root.path).map(\.path))

        #expect(hits.contains(root.appendingPathComponent("App/bin").path))
        #expect(hits.contains(root.appendingPathComponent("App/obj").path))
        #expect(!hits.contains(root.appendingPathComponent("Tool/bin").path))
        #expect(!hits.contains(root.appendingPathComponent("Tool/obj").path))
    }

    /// The refusal that justifies the marker rule existing. A Python virtualenv
    /// keeps `python`, `pip` and `activate` in `bin/` — a `find -name bin` sweep
    /// over a developer's home destroys every virtualenv on the disk. Checked
    /// for the un-hidden spellings too, so the guarantee does not rest on the
    /// prune list catching `.venv`.
    @Test func virtualenvBinIsNeverOffered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for venv in [".venv", "venv", "env", "virtualenv"] {
            try Self.makeFile(root, "Py/\(venv)/bin/activate")
            try Self.makeFile(root, "Py/\(venv)/pyvenv.cfg")
        }
        // A real .NET project in the same tree, so the walk is definitely
        // reaching this directory and choosing not to offer the venvs.
        try Self.makeFile(root, "Py/Native/Native.csproj")
        _ = try Self.makeDir(root, "Py/Native/bin")

        let hits = CleanupDiscovery.walkForArtifacts(home: root.path).map(\.path)

        #expect(hits.contains(root.appendingPathComponent("Py/Native/bin").path))
        #expect(!hits.contains { $0.contains("venv") || $0.contains("/env/") })
    }

    /// A `target/` is Cargo's only when a `Cargo.toml` sits beside it — the
    /// name is far too common to trust on its own.
    @Test func cargoTargetNeedsItsManifest() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "Crate/Cargo.toml")
        _ = try Self.makeDir(root, "Crate/target/debug")
        _ = try Self.makeDir(root, "Deploy/target") // a build output of something else

        let hits = CleanupDiscovery.walkForArtifacts(home: root.path)

        #expect(hits.map(\.path) == [root.appendingPathComponent("Crate/target").path])
        #expect(hits.first?.rule.directory == "target")
    }

    /// Matched directories are not descended into: a nested `bin/obj` inside
    /// build output is part of the artifact already, and counting it twice would
    /// double-count its bytes in the row's total.
    @Test func matchedDirectoriesAreNotDescendedInto() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/App.csproj")
        try Self.makeFile(root, "App/bin/Debug/Nested/Nested.csproj")
        _ = try Self.makeDir(root, "App/bin/Debug/Nested/bin")

        let hits = CleanupDiscovery.walkForArtifacts(home: root.path).map(\.path)

        #expect(hits == [root.appendingPathComponent("App/bin").path])
    }

    /// `node_modules` is pruned: it is the single biggest cost in the walk, and
    /// a project vendored inside one is not the user's to clean here.
    @Test func prunedDirectoriesAreNotEntered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "Web/node_modules/pkg/Vendored.csproj")
        _ = try Self.makeDir(root, "Web/node_modules/pkg/bin")

        #expect(CleanupDiscovery.walkForArtifacts(home: root.path).isEmpty)
    }

    /// The depth bound holds, so a pathological tree cannot turn the mode's load
    /// into a full-disk scan.
    @Test func walkStopsAtMaxDepth() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = (0..<10).map { "d\($0)" }.joined(separator: "/")
        try Self.makeFile(root, "\(deep)/App.csproj")
        _ = try Self.makeDir(root, "\(deep)/bin")

        #expect(CleanupDiscovery.walkForArtifacts(home: root.path, maxDepth: 3).isEmpty)
        #expect(CleanupDiscovery.walkForArtifacts(home: root.path, maxDepth: 12).count == 1)
    }

    /// Discovered targets are removed directory-and-all (MSBuild recreates
    /// them), unlike caches whose root must survive.
    @Test func projectArtifactsRemoveTheDirectoryItself() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/App.csproj")
        try Self.makeFile(root, "App/bin/App.dll", bytes: 8192)

        let targets = CleanupDiscovery.projectArtifacts(home: root.path)
        let dotnet = try #require(targets.first { $0.id == "dotnet-artifacts" })
        #expect(dotnet.removal == .directory)

        let result = CleanupEngine.clean(dotnet, allowedRoot: root.path)
        #expect(result.removed == 1)
        #expect(result.failed == 0 && result.refused == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("App/bin").path))
        // The project itself is untouched — only its output went.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("App/App.csproj").path))
    }

    /// Discovery gets no weaker a fence than the hand-written catalog: a
    /// discovered path that resolves outside the allowed root is refused at
    /// cleaning time, not chased.
    @Test func discoveredPathsStillObeyTheFence() throws {
        let root = try Self.fixture()
        let outside = try Self.fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Self.makeFile(outside, "keep.bin")
        let item = Cleanable(id: "dotnet-artifacts", name: "fixture", category: "t", icon: "x",
                             note: "n", paths: [outside.path], removal: .directory)

        let result = CleanupEngine.clean(item, allowedRoot: root.path)

        #expect(result.refused == 1)
        #expect(result.removed == 0)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.bin").path))
    }

    // MARK: Workspace storage

    /// The finding this target exists to correct. Emptying `workspaceStorage`
    /// wholesale is the usual advice and it is wrong: most folders belong to
    /// projects still on the disk, and the bytes are chat transcripts nothing
    /// regenerates. Only the folders whose project is gone are offered.
    @Test func onlyWorkspacesWhoseFolderIsGoneAreOffered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try Self.makeDir(root, "sources/live-repo")
        let storage = "Library/Application Support/Code/User/workspaceStorage"

        try Self.makeFile(root, "\(storage)/aaa/workspace.json", bytes: 0)
        try #"{"folder":"file://\#(live.path)"}"#
            .write(toFile: root.appendingPathComponent("\(storage)/aaa/workspace.json").path,
                   atomically: true, encoding: .utf8)
        try Self.makeFile(root, "\(storage)/aaa/chatSessions/s.json", bytes: 4096)

        try Self.makeFile(root, "\(storage)/bbb/workspace.json", bytes: 0)
        try #"{"folder":"file:///nope/deleted-repo"}"#
            .write(toFile: root.appendingPathComponent("\(storage)/bbb/workspace.json").path,
                   atomically: true, encoding: .utf8)

        let targets = CleanupDiscovery.orphanedWorkspaceStorage(home: root.path)
        let target = try #require(targets.first)

        #expect(target.paths == [root.appendingPathComponent("\(storage)/bbb").path])
        // Transcripts do not come back, so the row is never swept up by
        // select-all even though deleting it breaks nothing.
        #expect(target.regenerable == false)
        #expect(target.removal == .directory)
        #expect(target.ownerBundleID == "com.microsoft.VSCode")
    }

    /// Fails closed on anything it cannot resolve. A malformed or absent
    /// `workspace.json`, or a workspace that is not local, is kept — local
    /// absence proves nothing about a remote workspace.
    @Test func unresolvableWorkspacesAreKept() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = "Library/Application Support/Code/User/workspaceStorage"

        _ = try Self.makeDir(root, "\(storage)/no-json")
        try Self.makeFile(root, "\(storage)/bad-json/workspace.json", bytes: 0)
        try "not json at all".write(
            toFile: root.appendingPathComponent("\(storage)/bad-json/workspace.json").path,
            atomically: true, encoding: .utf8)
        try Self.makeFile(root, "\(storage)/remote/workspace.json", bytes: 0)
        try #"{"folder":"vscode-remote://ssh-remote%2Bbox/home/me/repo"}"#.write(
            toFile: root.appendingPathComponent("\(storage)/remote/workspace.json").path,
            atomically: true, encoding: .utf8)

        #expect(CleanupDiscovery.orphanedWorkspaceStorage(home: root.path).isEmpty)
        #expect(CleanupDiscovery.localPath(fromFileURI: "vscode-remote://x/y") == nil)
        #expect(CleanupDiscovery.localPath(fromFileURI: "file:///tmp/a%20b") == "/tmp/a b")
    }

    // MARK: Browser caches

    /// Profile directory names are generated, so the paths are found rather than
    /// written down — but they stay inside the browser's cache tree, and only on
    /// the subdirectories that hold fetched assets.
    @Test func browserCachesFindProfilesWithoutLeavingTheCacheTree() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "Library/Caches/Google/Chrome/Default/Cache/f")
        try Self.makeFile(root, "Library/Caches/Google/Chrome/Default/Code Cache/f")
        try Self.makeFile(root, "Library/Caches/Google/Chrome/Default/Storage/keep")
        try Self.makeFile(root, "Library/Caches/Firefox/Profiles/ab12.default-release/cache2/f")

        let targets = CleanupDiscovery.browserCaches(home: root.path)
        let chrome = try #require(targets.first { $0.id == "chrome-cache" })
        let firefox = try #require(targets.first { $0.id == "firefox-cache" })

        #expect(chrome.ownerBundleID == "com.google.Chrome")
        #expect(chrome.removal == .children) // the cache directory itself must survive
        // `Storage` is per-extension state, not fetched assets.
        #expect(!chrome.paths.contains { $0.hasSuffix("/Storage") })
        #expect(chrome.paths.allSatisfy { $0.contains("/Library/Caches/Google/Chrome/") })
        #expect(firefox.paths.allSatisfy { $0.contains("/Library/Caches/Firefox/Profiles/") })
    }

    // MARK: Cold dependency trees

    /// `node_modules` is regenerable but only from the network, so unlike build
    /// output it is offered on age rather than on the marker alone. A tree
    /// installed recently belongs to a project someone is working on.
    @Test func nodeModulesIsOfferedOnlyOnceItHasGoneCold() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "Warm/package.json")
        try Self.makeFile(root, "Warm/node_modules/pkg/index.js")
        try Self.makeFile(root, "Cold/package.json")
        try Self.makeFile(root, "Cold/node_modules/pkg/index.js")
        // Backdate the cold tree past the six-month gate.
        let cold = root.appendingPathComponent("Cold/node_modules")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-200 * 86_400)], ofItemAtPath: cold.path)

        let hits = CleanupDiscovery.walkForArtifacts(home: root.path).map(\.path)
        #expect(hits == [cold.path])

        let targets = CleanupDiscovery.projectArtifacts(home: root.path)
        let node = try #require(targets.first { $0.id == "cold-node-modules" })
        #expect(node.removal == .directory)
        #expect(node.regenerable) // it does come back, just slowly and online
        #expect(node.note.contains("npm install"))
    }

    /// A rule with no age gate is unaffected by mtime — build output is offered
    /// the moment it exists.
    @Test func buildOutputHasNoAgeGate() throws {
        var fresh = stat()
        fresh.st_mtimespec.tv_sec = Int(Date().timeIntervalSince1970)
        let build = CleanupDiscovery.ArtifactRule(directory: "bin", markers: [".csproj"])
        let aged = CleanupDiscovery.ArtifactRule(directory: "node_modules",
                                                 markers: ["package.json"], minimumAgeDays: 180)
        #expect(CleanupDiscovery.isOldEnough(fresh, for: build))
        #expect(!CleanupDiscovery.isOldEnough(fresh, for: aged))

        var old = stat()
        old.st_mtimespec.tv_sec = Int(Date().addingTimeInterval(-200 * 86_400).timeIntervalSince1970)
        #expect(CleanupDiscovery.isOldEnough(old, for: aged))
    }

    /// The walk must not descend into a matched `node_modules` even when it is
    /// too warm to offer — walking one is the single most expensive thing this
    /// code could do, and there is nothing inside it to find.
    @Test func warmNodeModulesIsSkippedNotEntered() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/package.json")
        // A nested project inside node_modules would be a hit if we descended.
        try Self.makeFile(root, "App/node_modules/dep/dep.csproj")
        _ = try Self.makeDir(root, "App/node_modules/dep/bin")

        #expect(CleanupDiscovery.walkForArtifacts(home: root.path).isEmpty)
    }

    // MARK: Single-path classification

    /// `explain` must reach the same verdict as the walk, without walking. The
    /// refusals are the half that matters: they are the advice an assistant
    /// reading a size table would otherwise get wrong.
    @Test func classifyMatchesTheWalkWithoutWalking() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/App.csproj")
        _ = try Self.makeDir(root, "App/bin")
        try Self.makeFile(root, "Crate/Cargo.toml")
        _ = try Self.makeDir(root, "Crate/target")
        try Self.makeFile(root, "Py/.venv/pyvenv.cfg")
        _ = try Self.makeDir(root, "Py/.venv/bin")
        _ = try Self.makeDir(root, "Go/bin")

        func classify(_ rel: String) -> CleanupDiscovery.Classification? {
            CleanupDiscovery.classify(root.appendingPathComponent(rel).path, home: root.path)
        }

        guard case .cleanable(let dotnet, _) = classify("App/bin") else {
            Issue.record("App/bin should be cleanable"); return
        }
        #expect(dotnet == ".NET build output")
        guard case .cleanable(let cargo, _) = classify("Crate/target") else {
            Issue.record("Crate/target should be cleanable"); return
        }
        #expect(cargo == "Cargo build output")

        // A virtualenv is named as such, not just refused — the reason is what
        // stops the next suggestion.
        guard case .protected(let venv) = classify("Py/.venv/bin") else {
            Issue.record("virtualenv bin should be protected"); return
        }
        #expect(venv.contains("virtualenv"))
        guard case .protected = classify("Go/bin") else {
            Issue.record("unmarked bin should be protected"); return
        }
        #expect(classify("App") == nil) // an ordinary directory is neither
    }

    /// The workspace-storage root reports measured counts rather than prose,
    /// because prose in a reference file did not stop the wrong advice being
    /// given: the summary has to arrive with the numbers attached.
    @Test func workspaceStorageRootReportsLiveVersusOrphaned() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try Self.makeDir(root, "sources/live")
        let storage = "Library/Application Support/Code/User/workspaceStorage"
        for (hash, folder) in [("a", live.path), ("b", live.path), ("c", "/gone/repo")] {
            try Self.makeFile(root, "\(storage)/\(hash)/workspace.json", bytes: 0)
            try #"{"folder":"file://\#(folder)"}"#.write(
                toFile: root.appendingPathComponent("\(storage)/\(hash)/workspace.json").path,
                atomically: true, encoding: .utf8)
        }

        guard case .protected(let summary) =
                CleanupDiscovery.classify(root.appendingPathComponent(storage).path, home: root.path)
        else { Issue.record("the storage root should be protected"); return }

        #expect(summary.contains("3 workspaces"))
        #expect(summary.contains("2 still")) // live
        #expect(summary.contains("1 are orphaned") || summary.contains("1 orphaned"))
        #expect(summary.contains("chatSessions"))

        // A live workspace's own folder is protected; the dead one is offered.
        guard case .protected = CleanupDiscovery.classify(
            root.appendingPathComponent("\(storage)/a").path, home: root.path)
        else { Issue.record("a live workspace must not be offered"); return }
        guard case .cleanable = CleanupDiscovery.classify(
            root.appendingPathComponent("\(storage)/c").path, home: root.path)
        else { Issue.record("an orphaned workspace should be offered"); return }
    }

    // MARK: The MCP surface

    /// End-to-end through the actual tool call, because the classifier being
    /// right is only half of it — an assistant only benefits if `explain` says
    /// so on the wire. This is the exact failure being fixed: a session that
    /// reads a size table, sees gigabytes of `bin/`, and proposes `rm -rf`.
    @Test func explainTellsTheModelWhichBinFoldersAreBuildOutput() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "App/App.csproj")
        try Self.makeFile(root, "App/bin/App.dll", bytes: 8192)
        try Self.makeFile(root, "Py/pyvenv.cfg")
        try Self.makeFile(root, "Py/bin/python", bytes: 8192)

        let server = MCPServer(source: DetachedScanSource(rootPath: root.path))
        func explain(_ relative: String) throws -> String {
            let request = try #require(JSONRPC.parse(line: """
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"explain",\
                "arguments":{"path":"\(root.appendingPathComponent(relative).path)"}}}
                """))
            let response = try #require(server.respond(to: request))
            let result = try #require(response["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            return try #require(content.first?["text"] as? String)
        }

        let buildOutput = try explain("App/bin")
        #expect(buildOutput.contains("Known cleanup target \".NET build output\""))
        #expect(buildOutput.contains("do not propose a shell command"))

        // The refusal is the load-bearing half.
        let venv = try explain("Py/bin")
        #expect(venv.contains("NOT a cleanup target"))
        #expect(venv.contains("virtualenv"))
    }

    // MARK: Podman machine disk

    /// The image path is derived from the one machine path podman reports.
    /// Pinned because the layout is podman's, not ours.
    @Test func machineDiskImageIsFoundByName() throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeFile(root, "applehv/podman-machine-default-arm64.raw")
        try Self.makeFile(root, "applehv/efi-bl-podman-machine-default")
        try Self.makeFile(root, "libkrun/other-machine-arm64.raw")

        #expect(CleanupDiscovery.localPath(fromFileURI: "file://\(root.path)") == root.path)
        #expect(ContainerQueries.findDiskImage(machineRoot: root.path, name: "podman-machine-default")
                == root.appendingPathComponent("applehv/podman-machine-default-arm64.raw").path)
        #expect(ContainerQueries.findDiskImage(machineRoot: root.path, name: "absent") == nil)
    }
}
