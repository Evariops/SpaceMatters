import Foundation

/// Cleanup targets whose paths cannot be written down ahead of time.
///
/// The hand-picked catalog in `CleanupEngine` works because every path is a
/// constant: the argument for deleting `~/.npm/_cacache` is made once, in prose,
/// next to the path. That does not scale to the three largest findings on a
/// developer's Mac — per-project build output, per-workspace editor state, and
/// per-profile browser caches — because their locations depend on what happens
/// to be on the disk.
///
/// These targets replace the hand-written argument with a *structural* one. Each
/// discovery below pairs a candidate directory with a fact on disk that explains
/// it, and offers nothing it cannot pair:
///
/// - a `bin/` is offered only next to a project file that produces one;
/// - a workspace-state folder only once the workspace it belongs to is gone;
/// - a browser cache only inside the browser's dedicated cache tree.
///
/// The rejected candidates are the point. A `find -name bin` over a developer's
/// home hits Python virtualenv `bin/` directories (where `python`, `pip` and
/// `activate` live) and Go output directories holding compiled binaries. The
/// marker rule is what tells those apart from MSBuild output, and it is cheap:
/// one directory read of the parent.
///
/// Discovery never widens the safety fence — `CleanupEngine.passesFence` still
/// gates every path, and cleaning still runs through `CleanupEngine.clean`. It
/// only decides which paths are put forward.
enum CleanupDiscovery {

    /// Every discovered target, or none when nothing qualifies. Runs a bounded
    /// directory walk, so callers must keep it off the main thread.
    static func all(home: String = NSHomeDirectory()) -> [Cleanable] {
        [projectArtifacts(home: home),
         orphanedWorkspaceStorage(home: home),
         browserCaches(home: home)]
            .flatMap { $0 }
    }

    // MARK: Project build artifacts

    /// A build-output directory name, and the project files that would explain
    /// finding one. A directory qualifies only when its *parent* contains at
    /// least one matching marker.
    struct ArtifactRule {
        let directory: String
        let markers: [String]
    }

    /// `bin` and `obj` are the dangerous pair and the valuable one: together
    /// they are routinely the single largest reclaimable finding on a .NET
    /// developer's disk, and `bin` is also the name Python virtualenvs and Go
    /// projects use for things that must not be deleted. Every rule here is
    /// marker-gated for that reason — including the unambiguous ones, so the
    /// invariant holds by construction rather than by which name we trusted.
    static let artifactRules: [ArtifactRule] = [
        ArtifactRule(directory: "bin", markers: [".csproj", ".fsproj", ".vbproj", ".sln", ".slnx"]),
        ArtifactRule(directory: "obj", markers: [".csproj", ".fsproj", ".vbproj", ".sln", ".slnx"]),
        ArtifactRule(directory: "target", markers: ["Cargo.toml"]),
    ]

    /// Directory names never descended into. `node_modules` and `.git` are the
    /// two that dominate the cost of the walk; the rest are large trees that by
    /// definition contain no project of the user's own.
    static let pruned: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "Library", ".Trash",
        "DerivedData", ".build", ".venv", "venv", "vendor", "Pods",
    ]

    /// Depth below `home` the walk is allowed to reach. Deep enough for the
    /// nesting real repositories use (`~/sources/org/repo/src/Project/bin`),
    /// shallow enough that a pathological tree cannot turn the mode's load into
    /// a full-disk scan.
    static let maxDepth = 8

    /// `bin`/`obj`/`target` directories that sit next to a project file
    /// explaining them, collapsed into one target per ecosystem.
    ///
    /// One row rather than one per directory: the user's decision is "drop .NET
    /// build output", not seventeen hundred individual ones, and the row carries
    /// the count so the scale is not hidden. Removal is `.directory` — MSBuild
    /// and Cargo recreate their output directory without being asked, and
    /// leaving a thousand empty `obj/` folders behind would be its own mess.
    ///
    /// Not offered as a native `dotnet clean`: that command cleans one
    /// configuration of one project at a time, leaves `Release/` and
    /// `project.assets.json` untouched, needs a restore and the exact SDK a
    /// `global.json` pins. Measured on a two-configuration hello-world it freed
    /// 28% of `bin`+`obj`. Removing the directory is both the more complete
    /// answer and the faster one — the opposite of the `go clean -modcache`
    /// case, where the vendor tool is the only thing that works at all.
    static func projectArtifacts(home: String = NSHomeDirectory()) -> [Cleanable] {
        let found = walkForArtifacts(home: home)
        guard !found.isEmpty else { return [] }

        let dotnet = found.filter { $0.rule.directory != "target" }.map(\.path)
        let rust = found.filter { $0.rule.directory == "target" }.map(\.path)

        var out: [Cleanable] = []
        if !dotnet.isEmpty {
            out.append(Cleanable(
                id: "dotnet-artifacts", name: ".NET build output", category: ".NET",
                icon: "hammer.fill",
                note: "bin/ and obj/ next to a project file. Recreated by the next build.",
                paths: dotnet.sorted(), removal: .directory,
                locationLabel: "\(dotnet.count) folders"))
        }
        if !rust.isEmpty {
            out.append(Cleanable(
                id: "cargo-artifacts", name: "Cargo build output", category: "Rust & Go",
                icon: "wrench.and.screwdriver.fill",
                note: "target/ next to a Cargo.toml. Recreated by the next build.",
                paths: rust.sorted(), removal: .directory,
                locationLabel: "\(rust.count) folders"))
        }
        return out
    }

    struct ArtifactHit {
        let path: String
        let rule: ArtifactRule
    }

    /// Iterative, depth-bounded walk of `home`. Deliberately not
    /// `FileManager.enumerator`: a matched directory must not be descended into
    /// (its own children are more build output, not more candidates), and
    /// pruning `node_modules` is what keeps this to seconds rather than minutes.
    static func walkForArtifacts(home: String, maxDepth: Int = maxDepth) -> [ArtifactHit] {
        var hits: [ArtifactHit] = []
        var queue: [(path: String, depth: Int)] = [(home, 0)]
        let rulesByName = Dictionary(uniqueKeysWithValues: artifactRules.map { ($0.directory, $0) })

        while let (dir, depth) = queue.popLast() {
            guard depth < maxDepth else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue // unreadable: not an error worth surfacing, just less coverage
            }
            // One pass to remember the names present, so the marker test for a
            // child costs no extra directory read.
            let names = Set(entries)
            for entry in entries {
                guard !pruned.contains(entry) else { continue }
                // Hidden directories hold configuration and tool state, never
                // the build output we are after; skipping them also keeps the
                // walk out of caches that have their own catalog entry.
                if entry.hasPrefix(".") { continue }
                let child = dir + "/" + entry
                var st = stat()
                guard lstat(child, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }

                if let rule = rulesByName[entry], names.contains(where: { matches($0, rule) }) {
                    hits.append(ArtifactHit(path: child, rule: rule))
                    continue // its contents are the artifact; nothing to find inside
                }
                queue.append((child, depth + 1))
            }
        }
        return hits
    }

    /// True when a sibling file name is one of the rule's markers — an exact
    /// name (`Cargo.toml`) or an extension (`.csproj`).
    static func matches(_ name: String, _ rule: ArtifactRule) -> Bool {
        rule.markers.contains { $0.hasPrefix(".") ? name.hasSuffix($0) : name == $0 }
    }

    // MARK: VS Code workspace storage

    /// Editors that use the VS Code workspace-storage layout, and the bundle id
    /// that must not be running while it is cleaned (`state.vscdb` is an open
    /// SQLite database).
    static let workspaceStorageHosts: [(support: String, name: String, bundleID: String)] = [
        ("Code", "VS Code", "com.microsoft.VSCode"),
        ("Code - Insiders", "VS Code Insiders", "com.microsoft.VSCodeInsiders"),
        ("Cursor", "Cursor", "com.todesktop.230313mzl4w4u92"),
        ("VSCodium", "VSCodium", "com.vscodium"),
    ]

    /// Per-workspace editor state whose workspace no longer exists on disk.
    ///
    /// This folder is a standing trap for disk-space advice. It grows without
    /// bound, it is full of hash-named directories, and it *looks* like a cache
    /// — so the usual recommendation is to empty the whole thing, described as
    /// costing "editor layout and undo history". Measured, that is wrong twice
    /// over: the bulk of the bytes is `chatSessions` and `chatEditingSessions`
    /// — AI conversation transcripts, which nothing regenerates — and most
    /// folders belong to repositories that are still on the disk.
    ///
    /// So the target is not the folder. Each subdirectory carries a
    /// `workspace.json` naming the project it belongs to; the ones whose project
    /// is gone are unreachable state and genuinely safe, and they are the only
    /// ones offered. A workspace still on disk is left alone however cold it
    /// looks, because opening it again is what makes its transcripts matter.
    static func orphanedWorkspaceStorage(home: String = NSHomeDirectory()) -> [Cleanable] {
        var out: [Cleanable] = []
        for host in workspaceStorageHosts {
            let root = home + "/Library/Application Support/\(host.support)/User/workspaceStorage"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            let orphans = entries.map { root + "/" + $0 }.filter { isOrphanedWorkspace($0) }
            guard !orphans.isEmpty else { continue }
            out.append(Cleanable(
                id: "workspace-storage-\(host.support.replacingOccurrences(of: " ", with: "-").lowercased())",
                name: "\(host.name) orphaned workspace state", category: "Editors",
                icon: "curlybraces.square",
                note: "State for \(orphans.count) workspace\(orphans.count == 1 ? "" : "s") "
                    + "whose folder no longer exists. Folders still on disk are left alone.",
                paths: orphans.sorted(), removal: .directory, regenerable: false,
                ownerBundleID: host.bundleID,
                locationLabel: "\(orphans.count) of \(entries.count) workspaces"))
        }
        return out
    }

    /// True when the directory is a workspace-storage entry whose target is
    /// gone. Fails closed at every step: an entry without a readable
    /// `workspace.json`, or one naming something this code cannot resolve, is
    /// kept rather than offered.
    static func isOrphanedWorkspace(_ directory: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: directory + "/workspace.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // "folder" for a plain directory, "configPath" for a .code-workspace
        // file. An entry with neither (a remote or virtual workspace) is not
        // something local existence can decide — leave it.
        guard let uri = (json["folder"] as? String) ?? (json["configPath"] as? String),
              let path = localPath(fromFileURI: uri)
        else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Local filesystem path behind a `file://` URI, or nil for any other
    /// scheme (`vscode-remote://`, `vscode-vfs://`): a remote workspace missing
    /// locally proves nothing about whether it still exists.
    static func localPath(fromFileURI uri: String) -> String? {
        guard uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: Single-path classification (for `explain`)

    /// What a *single* path is, in discovery's terms.
    enum Classification {
        /// Discovery would offer this path, for the stated reason.
        case cleanable(name: String, note: String)
        /// Discovery deliberately would not, and saying so is the point: these
        /// are the paths whose name or neighbourhood makes them look reclaimable
        /// when they are not.
        case protected(reason: String)
    }

    /// Classify one path without walking anything.
    ///
    /// `explain` is called per path and must stay instant, so it cannot run the
    /// discovery walk. Every rule discovery uses is local to the candidate
    /// anyway — a sibling marker, a `workspace.json` — so the same decision can
    /// be reached by looking only at the path itself.
    ///
    /// The `protected` answers matter as much as the `cleanable` ones. An
    /// assistant reading a size table sees a thousand `bin/` folders and a
    /// `workspaceStorage` full of hash-named directories and reaches for
    /// `rm -rf`; this is where it finds out which of those are a virtualenv and
    /// which workspace still exists.
    static func classify(_ path: String, home: String = NSHomeDirectory()) -> Classification? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent

        // Build output — or a directory that merely shares its name.
        if let rule = artifactRules.first(where: { $0.directory == name }) {
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            if siblings.contains(where: { matches($0, rule) }) {
                return .cleanable(
                    name: rule.directory == "target" ? "Cargo build output" : ".NET build output",
                    note: "Build output, recreated by the next build. SpaceMatters removes these "
                        + "itself. Note `dotnet clean` is not equivalent — it cleans one "
                        + "configuration and leaves the rest.")
            }
            if siblings.contains("pyvenv.cfg") {
                return .protected(
                    reason: "This is a Python virtualenv's bin/ — it holds the interpreter, pip "
                        + "and activate. Deleting it breaks the environment; remove the whole "
                        + "virtualenv instead, or leave it.")
            }
            return .protected(
                reason: "No project file sits beside this \(name)/, so nothing explains it as "
                    + "build output — Go projects keep compiled binaries there, and virtualenvs "
                    + "keep their interpreter. Not safe to sweep by name.")
        }

        // Per-workspace editor state.
        for host in workspaceStorageHosts {
            let storage = home + "/Library/Application Support/\(host.support)/User/workspaceStorage"
            if path == storage { return .protected(reason: workspaceStorageSummary(storage, host: host.name)) }
            guard parent == storage else { continue }
            if isOrphanedWorkspace(path) {
                return .cleanable(
                    name: "\(host.name) orphaned workspace state",
                    note: "The folder this state belongs to no longer exists, so nothing can "
                        + "reach it again. Not regenerable — it is state, not a cache.")
            }
            return .protected(
                reason: "State for a workspace that is still on disk. Most of the bytes here are "
                    + "chat transcripts (chatSessions / chatEditingSessions), which nothing "
                    + "regenerates — this is not editor layout.")
        }
        return nil
    }

    /// The measured shape of a `workspaceStorage` directory: how many of its
    /// workspaces are actually dead, and how much of it is conversation history.
    ///
    /// Written because the usual advice for this folder — empty it, it is only
    /// editor layout — is wrong in both halves, and prose in a reference file
    /// did not stop it being given. A number measured at the moment of asking
    /// does.
    static func workspaceStorageSummary(_ storage: String, host: String) -> String {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: storage)) ?? []
        let orphans = entries.filter { isOrphanedWorkspace(storage + "/" + $0) }.count
        let live = entries.count - orphans
        return "\(host) workspace state: \(entries.count) workspaces, of which \(live) still "
            + "exist on disk and \(orphans) are orphaned. Do NOT propose emptying this folder: "
            + "the bulk of it is chat transcripts (chatSessions), which nothing regenerates, and "
            + "only the \(orphans) orphaned folder\(orphans == 1 ? "" : "s") "
            + "\(orphans == 1 ? "is" : "are") unreachable. SpaceMatters offers exactly those."
    }

    // MARK: Browser caches

    /// Browsers keep their cache under a profile directory whose name is
    /// generated (`xxg0zp7b.default-release`, `Profile 1`), so the paths have to
    /// be found rather than written down.
    ///
    /// Both entries stay inside `~/Library/Caches`, which for these two browsers
    /// is a genuinely separate tree from the profile: history, passwords,
    /// cookies and extensions live under `Application Support` and are never
    /// touched here. That separation is what makes the target safe — it is not a
    /// claim about which subdirectory names look disposable.
    static func browserCaches(home: String = NSHomeDirectory()) -> [Cleanable] {
        var out: [Cleanable] = []
        let fm = FileManager.default

        // Chrome: ~/Library/Caches/Google/Chrome/<Profile>/{Cache, Code Cache,
        // image_cache}. `Storage` is deliberately excluded — it holds
        // per-extension state rather than fetched assets.
        let chromeRoot = home + "/Library/Caches/Google/Chrome"
        if let profiles = try? fm.contentsOfDirectory(atPath: chromeRoot) {
            let paths = profiles.flatMap { profile in
                ["Cache", "Code Cache", "image_cache"].map { "\(chromeRoot)/\(profile)/\($0)" }
            }.filter { fm.fileExists(atPath: $0) }
            if !paths.isEmpty {
                out.append(Cleanable(
                    id: "chrome-cache", name: "Chrome cache", category: "Browsers", icon: "globe",
                    note: "Fetched web assets, re-downloaded — quit Chrome first. History and "
                        + "logins are elsewhere and untouched.",
                    paths: paths.sorted(), ownerBundleID: "com.google.Chrome",
                    locationLabel: "\(profiles.count) profile\(profiles.count == 1 ? "" : "s")"))
            }
        }

        // Firefox: ~/Library/Caches/Firefox/Profiles/<profile>/{cache2,
        // startupCache}. The sibling JSON files are small and are the new-tab
        // page's state, so they are left in place.
        let firefoxRoot = home + "/Library/Caches/Firefox/Profiles"
        if let profiles = try? fm.contentsOfDirectory(atPath: firefoxRoot) {
            let paths = profiles.flatMap { profile in
                ["cache2", "startupCache"].map { "\(firefoxRoot)/\(profile)/\($0)" }
            }.filter { fm.fileExists(atPath: $0) }
            if !paths.isEmpty {
                out.append(Cleanable(
                    id: "firefox-cache", name: "Firefox cache", category: "Browsers", icon: "globe",
                    note: "Fetched web assets, re-downloaded — quit Firefox first. The profile "
                        + "itself is elsewhere and untouched.",
                    paths: paths.sorted(), ownerBundleID: "org.mozilla.firefox",
                    locationLabel: "\(profiles.count) profile\(profiles.count == 1 ? "" : "s")"))
            }
        }
        return out
    }
}
