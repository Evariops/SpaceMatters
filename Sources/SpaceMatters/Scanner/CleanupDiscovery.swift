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

    /// Every discovered target, or none when nothing qualifies. Runs bounded
    /// directory walks, so callers must keep it off the main thread.
    static func all(home: String = NSHomeDirectory(),
                    temporaryRoots: [String] = TemporaryFiles.roots()) -> [Cleanable] {
        passes(home: home, temporaryRoots: temporaryRoots).flatMap { $0.run() }
    }

    /// One discovery as the Low-Hanging Fruits mode runs it: the rows it can
    /// produce, and the search that decides which of them are real.
    ///
    /// The placeholders are what keeps the list still under the user. A search
    /// can take seconds, and rows that arrive late — whole sections appearing
    /// at the bottom of a list that looked finished — read as a different
    /// answer to the same question; rows that vanish read no better. So every
    /// target a search can plausibly produce is on screen from the first frame,
    /// in the section the real row will land in, and stays there: replaced by
    /// what the search found, or marked "none found".
    struct Pass: Sendable {
        /// Stand-ins, in the order the real rows should take. Cheap to build —
        /// at most a few `stat`s per target — because they are built on the
        /// main actor at every load. Since a stand-in never goes away, one is
        /// only put up where its target is plausible.
        let placeholders: [Cleanable]
        let run: @Sendable () -> [Cleanable]
    }

    static func passes(home: String = NSHomeDirectory(),
                       temporaryRoots: [String] = TemporaryFiles.roots()) -> [Pass] {
        let fm = FileManager.default
        func installed(_ traces: [String]) -> Bool {
            traces.contains { fm.fileExists(atPath: home + "/" + $0) }
        }
        // The walk itself cannot be predicted, but the toolchain behind each
        // target leaves a trace in the home on first use. No trace, no
        // stand-in: a Mac without Rust is not shown a Cargo row reading
        // "none found" forever. A trace that misses only makes a row late.
        let ecosystems: [(row: Cleanable, traces: [String])] = [
            (coldNodeModules([]), [".npm", ".bun", "Library/pnpm", "Library/Caches/Yarn", ".yarn"]),
            (dotnetArtifacts([]), [".nuget", ".dotnet"]),
            (cargoArtifacts([]), [".cargo", ".rustup"]),
        ]
        var out = [
            Pass(placeholders: ecosystems.filter { installed($0.traces) }
                    .map { $0.row.placeholder("searching ~…") },
                 run: { projectArtifacts(home: home) }),
            // One stand-in per editor actually installed, browsers likewise:
            // those roots are fixed, so a `stat` says whether a row can exist.
            Pass(placeholders: workspaceStorageHosts
                    .filter { fm.fileExists(atPath: workspaceStorageRoot(home: home, host: $0.support)) }
                    .map { orphanedWorkspaceRow(host: $0, orphans: [], total: 0).placeholder("searching…") },
                 run: { orphanedWorkspaceStorage(home: home) }),
            Pass(placeholders: browserRoots(home: home)
                    .filter { fm.fileExists(atPath: $0.root) }
                    .map { browserRow($0.browser, paths: [], profiles: 0).placeholder("searching…") },
                 run: { browserCaches(home: home) }),
        ]
        if !temporaryRoots.isEmpty {
            out.append(Pass(
                placeholders: [TemporaryFiles.row([], locationLabel: "searching…")],
                run: { TemporaryFiles.discover(roots: temporaryRoots).map { [$0] } ?? [] }))
        }
        return out
    }

    // MARK: Project build artifacts

    /// A build-output directory name, and the project files that would explain
    /// finding one. A directory qualifies only when its *parent* contains at
    /// least one matching marker.
    struct ArtifactRule {
        let directory: String
        let markers: [String]
        /// When set, the directory is only offered once it has gone this long
        /// untouched.
        ///
        /// Build output needs no such gate — the next build recreates it in
        /// seconds, from the source right beside it. A dependency tree does
        /// not: restoring it needs the network, the registry to still serve
        /// those versions, and minutes of waiting. That is regenerable enough
        /// to offer, but only for a project nobody has touched in months.
        var minimumAgeDays: Int?
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
        // Six months. Long enough that the project is genuinely dormant rather
        // than merely between installs, and it is the threshold that matches
        // what a human reviewing the same disk called cold.
        ArtifactRule(directory: "node_modules", markers: ["package.json"], minimumAgeDays: 180),
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

        let dotnet = found.filter { ["bin", "obj"].contains($0.rule.directory) }.map(\.path)
        let rust = found.filter { $0.rule.directory == "target" }.map(\.path)
        let node = found.filter { $0.rule.directory == "node_modules" }.map(\.path)

        var out: [Cleanable] = []
        if !node.isEmpty { out.append(coldNodeModules(node.sorted())) }
        if !dotnet.isEmpty { out.append(dotnetArtifacts(dotnet.sorted())) }
        if !rust.isEmpty { out.append(cargoArtifacts(rust.sorted())) }
        return out
    }

    /// Kept apart from the build-output rows on purpose. Those come back from
    /// the source next to them; this one comes back from a registry over the
    /// network, and only if it still serves the versions the lockfile pins.
    /// Same verdict, materially different cost — so it says "cold", says how
    /// many, and does not hide inside a row about build artifacts.
    static func coldNodeModules(_ paths: [String]) -> Cleanable {
        Cleanable(
            id: "cold-node-modules", name: "Cold node_modules", category: "JavaScript",
            icon: "shippingbox.circle",
            note: "Projects with no install for 6 months. `npm install` restores each — needs network.",
            paths: paths, removal: .directory,
            locationLabel: "\(paths.count) project\(paths.count == 1 ? "" : "s")")
    }

    static func dotnetArtifacts(_ paths: [String]) -> Cleanable {
        Cleanable(
            id: "dotnet-artifacts", name: ".NET build output", category: ".NET",
            icon: "hammer.fill",
            note: "bin/ and obj/ next to a project file. Recreated by the next build.",
            paths: paths, removal: .directory,
            locationLabel: "\(paths.count) folders")
    }

    static func cargoArtifacts(_ paths: [String]) -> Cleanable {
        Cleanable(
            id: "cargo-artifacts", name: "Cargo build output", category: "Rust & Go",
            icon: "wrench.and.screwdriver.fill",
            note: "target/ next to a Cargo.toml. Recreated by the next build.",
            paths: paths, removal: .directory,
            locationLabel: "\(paths.count) folders")
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
                // Hidden directories hold configuration and tool state, never
                // the build output we are after; skipping them also keeps the
                // walk out of caches that have their own catalog entry.
                if entry.hasPrefix(".") { continue }
                let child = dir + "/" + entry
                var st = stat()
                guard lstat(child, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }

                // Rules are tested before the prune list, because a name can be
                // in both: `node_modules` is never *descended* into, but it is
                // exactly what one rule is looking for. Either way the walk
                // stops here — whether the directory is a hit, too warm to
                // offer, or simply pruned, nothing inside it is a candidate.
                if let rule = rulesByName[entry] {
                    if names.contains(where: { matches($0, rule) }), isOldEnough(st, for: rule) {
                        hits.append(ArtifactHit(path: child, rule: rule))
                    }
                    continue
                }
                if pruned.contains(entry) { continue }
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

    /// Whether a candidate has been dormant long enough for its rule.
    ///
    /// A dependency tree's own mtime is the right clock here: package managers
    /// rewrite it on every install, and nothing else does. Editing the source
    /// beside it leaves it untouched, which is the intent — what matters is
    /// when the tree was last *populated*, not when the project was last read.
    /// Rules without a gate always pass.
    static func isOldEnough(_ st: stat, for rule: ArtifactRule, now: Date = Date()) -> Bool {
        guard let days = rule.minimumAgeDays else { return true }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        return now.timeIntervalSince(modified) >= TimeInterval(days) * 86_400
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
            let root = workspaceStorageRoot(home: home, host: host.support)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            let orphans = entries.map { root + "/" + $0 }.filter { isOrphanedWorkspace($0) }
            guard !orphans.isEmpty else { continue }
            out.append(orphanedWorkspaceRow(host: host, orphans: orphans.sorted(), total: entries.count))
        }
        return out
    }

    static func workspaceStorageRoot(home: String, host support: String) -> String {
        home + "/Library/Application Support/\(support)/User/workspaceStorage"
    }

    static func orphanedWorkspaceRow(host: (support: String, name: String, bundleID: String),
                                     orphans: [String], total: Int) -> Cleanable {
        Cleanable(
            id: "workspace-storage-\(host.support.replacingOccurrences(of: " ", with: "-").lowercased())",
            name: "\(host.name) orphaned workspace state", category: "Editors",
            icon: "curlybraces.square",
            note: "State for workspaces whose folder no longer exists. Folders still on disk are left alone.",
            paths: orphans, removal: .directory, regenerable: false,
            ownerBundleID: host.bundleID,
            locationLabel: "\(orphans.count) of \(total) workspaces")
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
                var st = stat()
                let warm = lstat(path, &st) == 0 && !isOldEnough(st, for: rule)
                if warm {
                    // The refusal that keeps an assistant from proposing
                    // `rm -rf node_modules` across a working tree.
                    return .protected(
                        reason: "A dependency tree for a project installed within the last 6 "
                            + "months. It restores only from the network, so it is offered only "
                            + "once the project has gone dormant.")
                }
                if rule.directory == "node_modules" {
                    return .cleanable(
                        name: "Cold node_modules",
                        note: "No install here for 6 months. `npm install` restores it, but that "
                            + "needs network and the registry still serving the pinned versions. "
                            + "SpaceMatters removes these itself.")
                }
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
            let storage = workspaceStorageRoot(home: home, host: host.support)
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
        let fm = FileManager.default
        return browserRoots(home: home).compactMap { entry in
            guard let profiles = try? fm.contentsOfDirectory(atPath: entry.root) else { return nil }
            let paths = profiles.flatMap { profile in
                entry.browser.caches.map { "\(entry.root)/\(profile)/\($0)" }
            }.filter { fm.fileExists(atPath: $0) }
            guard !paths.isEmpty else { return nil }
            return browserRow(entry.browser, paths: paths.sorted(), profiles: profiles.count)
        }
    }

    enum Browser: CaseIterable {
        case chrome, firefox

        /// Per-profile cache directories. Chrome's `Storage` is deliberately
        /// excluded — it holds per-extension state rather than fetched assets;
        /// Firefox's sibling JSON files are small and are the new-tab page's
        /// state, so they are left in place too.
        var caches: [String] {
            switch self {
            case .chrome: ["Cache", "Code Cache", "image_cache"]
            case .firefox: ["cache2", "startupCache"]
            }
        }
    }

    /// Where each browser keeps one folder per profile, inside the cache tree.
    static func browserRoots(home: String) -> [(browser: Browser, root: String)] {
        [(.chrome, home + "/Library/Caches/Google/Chrome"),
         (.firefox, home + "/Library/Caches/Firefox/Profiles")]
    }

    static func browserRow(_ browser: Browser, paths: [String], profiles: Int) -> Cleanable {
        let label = "\(profiles) profile\(profiles == 1 ? "" : "s")"
        switch browser {
        case .chrome:
            return Cleanable(
                id: "chrome-cache", name: "Chrome cache", category: "Browsers", icon: "globe",
                note: "Fetched web assets, re-downloaded — quit Chrome first. History and "
                    + "logins are elsewhere and untouched.",
                paths: paths, ownerBundleID: "com.google.Chrome", locationLabel: label)
        case .firefox:
            return Cleanable(
                id: "firefox-cache", name: "Firefox cache", category: "Browsers", icon: "globe",
                note: "Fetched web assets, re-downloaded — quit Firefox first. The profile "
                    + "itself is elsewhere and untouched.",
                paths: paths, ownerBundleID: "org.mozilla.firefox", locationLabel: label)
        }
    }
}
