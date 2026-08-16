import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A known-safe cleanup target for the Low-Hanging Fruits mode: a location whose
/// contents are regenerable by design (package/build caches) or explicitly
/// disposable (the Trash). Paths are absolute; only existing ones are shown.
struct Cleanable: Identifiable, Equatable, Sendable {

    /// What deleting the target means at the filesystem level.
    enum Removal: Equatable, Sendable {
        /// Empty the directory, keep it — the shape every *cache* wants: tools
        /// expect their cache root to exist, and recreating it is not their job.
        case children
        /// Remove the directory itself. Correct only where the directory is the
        /// artifact rather than a container for one (a `bin/` MSBuild recreates,
        /// a workspace-state folder whose workspace is gone) — a cache cleaned
        /// this way would come back as a missing-directory error in some tool.
        case directory
    }

    let id: String
    let name: String
    let category: String
    let icon: String
    /// What deleting costs the user ("re-downloaded on next install", …).
    let note: String
    var paths: [String]
    var removal: Removal = .children
    /// False when the bytes do not come back on their own: the Trash, and
    /// editor state for a workspace that no longer exists. Such a target is
    /// still offered — it is safe in the sense that nothing breaks — but it is
    /// never swept up by select-all, and the confirmation says what it is.
    /// Everything else is a cache that a re-download or a rebuild restores.
    var regenerable = true
    /// Bundle identifier of the desktop app that owns these files, when one
    /// does. While it runs the target is blocked: a running app holds its cache
    /// open, so unlinking underneath it frees nothing until quit and can leave
    /// the app's own index describing entries that no longer exist. See
    /// `appIsRunning` — this is the generalisation of the original Notion case.
    var ownerBundleID: String?
    /// Overrides the path column when listing every path would be noise
    /// ("1,722 folders under ~/sources"). Set by discovery, which is the only
    /// producer of targets with more paths than a row can show.
    var locationLabel: String?

    init(id: String, name: String, category: String, icon: String, note: String,
         paths: [String], removal: Removal = .children, regenerable: Bool = true,
         ownerBundleID: String? = nil, locationLabel: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.icon = icon
        self.note = note
        self.paths = paths
        self.removal = removal
        self.regenerable = regenerable
        self.ownerBundleID = ownerBundleID
        self.locationLabel = locationLabel
    }
}

/// Catalog, sizing and cleaning for the Low-Hanging Fruits mode.
///
/// Safety model (same spirit as `ScanController.remove`, J4.4):
/// - every operation is fenced inside `allowedRoot` (the user's home), so a
///   mis-built `Cleanable` can never reach outside it;
/// - cleaning a cache deletes its *children*, never the directory itself, and
///   never follows symlinks: a link inside a cache is removed as a link, its
///   target is left untouched; a cache root that *is* a symlink is refused
///   outright rather than resolved.
///
/// Two kinds of target reach this engine, and they earn their safety
/// differently:
/// - the **catalog** below is hand-picked. Every path is a constant, so the
///   argument for each one is made once, here, in prose;
/// - **discovered** targets (`CleanupDiscovery`) cannot be: their paths depend
///   on what is on the disk. They substitute a *structural* proof for the
///   hand-written one — a `bin/` is only offered next to a project file that
///   explains it, a workspace-state folder only once its workspace is gone.
///   Discovery never widens the fence; it only decides which paths enter it.
enum CleanupEngine {

    // MARK: Catalog

    /// Everything here is regenerable: emptying only costs a re-download or a
    /// rebuild. Entries whose paths don't exist are filtered out by `detect`.
    static func catalog(home: String = NSHomeDirectory()) -> [Cleanable] {
        [
            Cleanable(
                id: "trash", name: "Trash", category: "System", icon: "trash.fill",
                note: "Files you already deleted. Emptying is permanent.",
                paths: [home + "/.Trash"], regenerable: false),
            // Notion's service worker never evicts: it keeps one full asset
            // bucket per app release it has ever run (`notion-swv2-<version>`
            // in CacheStorage/*/index.txt), so the directory grows by a few
            // hundred MB per update and never shrinks. Deliberately narrow —
            // the two HTTP-level caches of the `notion` partition only. Its
            // siblings hold state the app cannot refetch: IndexedDB (unsynced
            // edits), File System (offline attachments), Local Storage,
            // Cookies (the session). See `notionIsRunning` for the live-app
            // guard — the reason this target is app-specific rather than a
            // generic "Electron caches" sweep.
            Cleanable(
                id: "notion", name: "Notion cache", category: "Apps", icon: "note.text",
                note: "Web assets, re-downloaded at next launch — quit Notion first.",
                paths: [
                    home + "/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage",
                    home + "/Library/Application Support/Notion/Partitions/notion/Cache",
                ],
                ownerBundleID: "notion.id"),
            // `~/Library/Caches/<bundle-id>` is macOS's own per-app cache
            // container: URL caches, thumbnails, downloaded assets. Named app by
            // app rather than swept, because the convention is a convention —
            // plenty of apps park recoverable-only-by-re-login state in there,
            // and `~/Library/Caches` also holds CloudKit and other system state
            // that is not an app cache at all.
            Cleanable(
                id: "slack", name: "Slack cache", category: "Apps", icon: "bubble.left.and.bubble.right.fill",
                note: "Downloaded files and images, re-fetched — quit Slack first.",
                paths: [home + "/Library/Caches/com.tinyspeck.slackmacgap"],
                ownerBundleID: "com.tinyspeck.slackmacgap"),
            Cleanable(
                id: "zoom", name: "Zoom cache", category: "Apps", icon: "video.fill",
                note: "Web view and asset caches, re-fetched — quit Zoom first.",
                paths: [home + "/Library/Caches/us.zoom.xos"],
                ownerBundleID: "us.zoom.xos"),
            // Updater downloads: installers kept after the update was applied.
            // Nothing reads them again — the next update downloads its own.
            Cleanable(
                id: "app-updaters", name: "App updater downloads", category: "Apps", icon: "arrow.down.circle.fill",
                note: "Installers kept after updating. Nothing reads them again.",
                paths: [
                    home + "/Library/Caches/bitwarden-updater",
                    home + "/Library/Caches/podman-desktop-updater",
                    home + "/Library/Application Support/Caches/bitwarden-updater",
                ]),
            Cleanable(
                id: "derived-data", name: "Xcode DerivedData", category: "Apple development", icon: "hammer.fill",
                note: "Per-project build artifacts. Xcode rebuilds them on demand.",
                paths: [home + "/Library/Developer/Xcode/DerivedData"]),
            Cleanable(
                id: "swiftpm", name: "SwiftPM cache", category: "Apple development", icon: "shippingbox.fill",
                note: "Package checkouts and manifests, re-fetched on next resolve.",
                paths: [home + "/Library/Caches/org.swift.swiftpm"]),
            Cleanable(
                id: "cocoapods", name: "CocoaPods cache", category: "Apple development", icon: "cube.fill",
                note: "Downloaded pod specs and archives, re-fetched on next install.",
                paths: [home + "/Library/Caches/CocoaPods"]),
            // `_npx` is a sibling of `_cacache` and routinely the larger of the
            // two: npm installs a throwaway tree per `npx <pkg>` invocation and
            // never evicts one. Same regenerability, so it belongs to the same
            // target rather than to one of its own.
            Cleanable(
                id: "npm", name: "npm cache", category: "JavaScript", icon: "shippingbox",
                note: "Package tarballs and one-off npx installs, re-downloaded on demand.",
                paths: [home + "/.npm/_cacache", home + "/.npm/_npx"]),
            Cleanable(
                id: "node-gyp", name: "node-gyp headers", category: "JavaScript", icon: "shippingbox",
                note: "Node headers per version, re-downloaded when a native module builds.",
                paths: [home + "/Library/Caches/node-gyp"]),
            Cleanable(
                id: "bun", name: "Bun cache", category: "JavaScript", icon: "shippingbox",
                note: "Package cache, re-downloaded on next install.",
                paths: [home + "/.bun/install/cache"]),
            Cleanable(
                id: "electron", name: "Electron downloads", category: "JavaScript", icon: "shippingbox",
                note: "Prebuilt Electron zips, re-downloaded on next install.",
                paths: [home + "/Library/Caches/electron"]),
            Cleanable(
                id: "typescript", name: "TypeScript type acquisition", category: "JavaScript", icon: "shippingbox",
                note: "Auto-acquired @types packages, re-fetched by the editor.",
                paths: [home + "/Library/Caches/typescript"]),
            // Deliberately *not* worded like the caches above. These are browser
            // binaries, not build artifacts: nothing re-downloads them on demand,
            // and every e2e run fails until `npx playwright install` is run by
            // hand. Regenerable, but not automatically — the note has to say so,
            // or the row promises something the target cannot deliver.
            Cleanable(
                id: "playwright", name: "Playwright browsers", category: "JavaScript", icon: "theatermasks.fill",
                note: "Browser binaries — needs an explicit `npx playwright install` before e2e tests run again.",
                paths: [home + "/Library/Caches/ms-playwright"]),
            Cleanable(
                id: "yarn", name: "Yarn cache", category: "JavaScript", icon: "shippingbox",
                note: "Package tarballs, re-downloaded on next install.",
                paths: [home + "/Library/Caches/Yarn"]),
            Cleanable(
                id: "pnpm", name: "pnpm store", category: "JavaScript", icon: "shippingbox",
                note: "Package store — projects keep their files (hard links), re-downloaded on demand.",
                paths: [home + "/Library/pnpm/store", home + "/.pnpm-store"]),
            Cleanable(
                id: "nuget", name: "NuGet packages", category: ".NET", icon: "archivebox.fill",
                note: "Global packages + HTTP cache, restored on next build (needs feed access).",
                paths: [
                    home + "/.nuget/packages",
                    home + "/.local/share/NuGet/http-cache",
                    home + "/.local/share/NuGet/v3-cache",
                ]),
            Cleanable(
                id: "pip", name: "pip cache", category: "Python", icon: "archivebox",
                note: "Wheel downloads, re-fetched on next install.",
                paths: [home + "/Library/Caches/pip"]),
            // uv puts its cache under XDG on *every* platform, so on a Mac the
            // real location is `~/.cache/uv` — not the `~/Library/Caches` one
            // the rest of this table uses. Listing only the Apple-shaped path
            // missed 4 GiB on the machine this was written for. Both are kept:
            // older uv builds did use Library/Caches, `detect` drops whichever
            // is absent, and a relocated cache (`UV_CACHE_DIR`, `cache-dir` in
            // uv.toml) is simply not found — a GUI app inherits no shell
            // environment, so reading the variable would be false more often
            // than true.
            Cleanable(
                id: "uv", name: "uv cache", category: "Python", icon: "archivebox",
                note: "Package cache, re-fetched on next sync.",
                paths: [xdgCache(home) + "/uv", home + "/Library/Caches/uv"]),
            Cleanable(
                id: "gradle", name: "Gradle caches", category: "JVM", icon: "gearshape.2.fill",
                note: "Dependency and build caches, re-downloaded on next build.",
                paths: [home + "/.gradle/caches"]),
            Cleanable(
                id: "maven", name: "Maven repository", category: "JVM", icon: "gearshape.2",
                note: "Re-downloaded on next build — except JARs installed by hand (install:install-file).",
                paths: [home + "/.m2/repository"]),
            Cleanable(
                id: "cargo", name: "Cargo registry", category: "Rust & Go", icon: "wrench.and.screwdriver.fill",
                note: "Crate downloads and sources, re-fetched on next build.",
                paths: [home + "/.cargo/registry"]),
            Cleanable(
                id: "go-build", name: "Go build cache", category: "Rust & Go", icon: "wrench.and.screwdriver",
                note: "Compiled build cache, rebuilt on demand.",
                paths: [home + "/Library/Caches/go-build"]),
            // GOPATH's default location only. A GUI app inherits no shell
            // environment, so `$GOPATH` would read empty here far more often
            // than it would read true; a relocated cache is simply not detected
            // (and if it lives outside home, the fence would refuse it anyway).
            // The clean itself doesn't rely on this path — `go clean -modcache`
            // resolves its own location, env overrides included.
            Cleanable(
                id: "go-mod", name: "Go module cache", category: "Rust & Go", icon: "shippingbox.circle.fill",
                note: "Module sources and zips, re-downloaded on next build (needs network).",
                paths: [home + "/go/pkg/mod"]),
            // Cross-platform tools ignore `~/Library/Caches` and follow XDG, so
            // they hide from anyone looking only in the Apple location.
            Cleanable(
                id: "pre-commit", name: "pre-commit hook environments", category: "Developer tools",
                icon: "checkmark.seal.fill",
                note: "Per-hook virtualenvs and clones, rebuilt on next run (needs network).",
                paths: [xdgCache(home) + "/pre-commit", xdgCache(home) + "/prek"]),
            Cleanable(
                id: "gh", name: "GitHub CLI cache", category: "Developer tools", icon: "terminal.fill",
                note: "Cached API responses, re-fetched on demand.",
                paths: [xdgCache(home) + "/gh"]),
            // One extracted tree per engine version ever run — a bundled Python
            // runtime and the analyser, not rules or results. Old versions are
            // pure waste; the current one is re-downloaded on the next scan.
            Cleanable(
                id: "opengrep", name: "Opengrep engine", category: "Developer tools",
                icon: "magnifyingglass",
                note: "Extracted engine, one tree per version — re-downloaded on next scan.",
                paths: [xdgCache(home) + "/opengrep", xdgCache(home) + "/semgrep"]),
            // Narrow on purpose. `~/.cache/opencode` holds downloaded helper
            // binaries (a language server, ripgrep) and the model list. Its
            // sibling `~/.local/share/opencode` holds `auth.json` and
            // `opencode.db` — the credentials and the conversation history —
            // and must never be swept up with it. Same app, same-looking name,
            // opposite verdict.
            Cleanable(
                id: "opencode", name: "opencode downloads", category: "Developer tools",
                icon: "terminal",
                note: "Helper binaries and the model list, re-fetched — sessions and login live "
                    + "elsewhere and are untouched.",
                paths: [xdgCache(home) + "/opencode"]),
            Cleanable(
                id: "homebrew", name: "Homebrew downloads", category: "Homebrew", icon: "mug.fill",
                note: "Bottle, cask and API downloads, re-fetched on demand.",
                paths: [home + "/Library/Caches/Homebrew"]),
        ]
    }

    /// The XDG cache root. macOS has no XDG convention of its own, but the
    /// tools that ignore `~/Library/Caches` all agree on this fallback, so it is
    /// where several gigabytes hide from anyone who only looks the Apple way.
    /// `XDG_CACHE_HOME` is deliberately not read: a GUI app inherits no shell
    /// environment, so it would be empty here far more often than it would be
    /// right (same reasoning as the Go module cache above).
    static func xdgCache(_ home: String) -> String { home + "/.cache" }

    /// The catalog restricted to entries with at least one path that passes the
    /// same fence as `clean` (existing real directory, no symlinked root, still
    /// inside `allowedRoot` once resolved). Deciding at detection time keeps the
    /// UI honest: a relocated cache is never shown, sized through its link, and
    /// then refused at cleaning time with gigabytes left on screen.
    static func detect(_ catalog: [Cleanable], allowedRoot: String = NSHomeDirectory()) -> [Cleanable] {
        catalog.compactMap { item in
            let existing = item.paths.filter { passesFence($0, allowedRoot: allowedRoot) }
            guard !existing.isEmpty else { return nil }
            var kept = item
            kept.paths = existing
            return kept
        }
    }

    // MARK: Sizing

    enum Measure: Equatable, Sendable {
        case sized(Int64)
        /// The location exists but can't be opened — typically the Trash without
        /// Full Disk Access.
        case denied
    }

    /// Physical bytes under the item's paths.
    ///
    /// The walk itself is `DirectoryScanner`, seeded with the item's paths
    /// instead of a volume — the engine is built for exactly this ("multiple
    /// seeds let a single scan span several volumes, all aggregating into a
    /// shared virtual root"), so a cache is measured by the same worker pool
    /// that scans a whole disk rather than by a second, single-threaded walk.
    /// Sizes reach `total` up the parent chain, so the seed nodes only need a
    /// parent, never to be attached as children.
    ///
    /// The roots are still opened here first, with `O_NOFOLLOW`, for two
    /// reasons the scanner cannot cover: it opens without `O_NOFOLLOW`, so a
    /// symlinked root would be measured *through* its link — precisely what
    /// `detect` and `clean` refuse — and it counts unreadable directories
    /// without distinguishing the one case the UI acts on, a root that exists
    /// but cannot be opened (the Trash without Full Disk Access).
    ///
    /// Counting matches `clean`: `exact: false`, so every hard link is counted,
    /// like the file removal that follows. Runs off the main thread; the pool
    /// is not shared, so callers size one item at a time.
    static func size(of item: Cleanable) -> Measure {
        let total = FSNode(name: "cleanup", parent: nil)
        var seeds: [DirectoryScanner.Seed] = []
        var deniedRoot = false

        for root in item.paths {
            let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else {
                // ENOENT and EACCES are different stories: a root that no
                // longer exists is *empty* (native cleaners like dotnet and go
                // remove their directories outright), only a root we're not
                // allowed to open reads as "needs access".
                if errno == EACCES || errno == EPERM { deniedRoot = true }
                continue
            }
            close(fd)
            seeds.append(DirectoryScanner.Seed(path: root, node: FSNode(name: root, parent: total)))
        }

        guard !seeds.isEmpty else { return deniedRoot ? .denied : .sized(0) }
        let scanner = DirectoryScanner(root: total, seeds: seeds)
        scanner.start()
        scanner.waitUntilFinished()
        return .sized(total.sizeOnDisk)
    }

    // MARK: Cleaning

    struct CleanResult: Equatable, Sendable {
        var removed = 0
        var failed = 0
        /// Paths refused by the safety fence (outside `allowedRoot`, or a
        /// symlinked root) — a bug indicator, surfaced rather than swallowed.
        var refused = 0
    }

    /// Delete each of the item's paths, or their children, per `item.removal`.
    /// For a cache the paths themselves survive (tools expect their cache
    /// directory to exist); for a `.directory` target the path is the artifact
    /// and goes with it. Every path must live strictly inside `allowedRoot`
    /// **once fully resolved** and be a real directory — a symlinked root, a
    /// symlinked *intermediate* component (`~/.gradle` → an external volume) or
    /// a `..` escape are all refused, so a cache relocated elsewhere is never
    /// chased.
    ///
    /// Concurrency note: the checks and the removals are separate syscalls
    /// (TOCTOU). The fence defends against catalog bugs and relocated caches —
    /// not against code already running as the same user, which could delete
    /// anything directly and gains nothing from racing this loop.
    static func clean(_ item: Cleanable, allowedRoot: String = NSHomeDirectory()) -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default

        for root in item.paths {
            var rootStat = stat()
            if lstat(root, &rootStat) != 0 {
                // A vanished root is nothing to clean, not a fence violation —
                // a native cleaner may have removed the directory outright.
                if errno != ENOENT { result.failed += 1 }
                continue
            }
            guard passesFence(root, allowedRoot: allowedRoot) else {
                result.refused += 1
                continue
            }
            if item.removal == .directory {
                // The fence has already established that `root` is a real
                // directory inside the home, reached without crossing a
                // symlink; removeItem then never escapes it.
                do {
                    try fm.removeItem(atPath: root)
                    result.removed += 1
                } catch {
                    result.failed += 1
                }
                continue
            }
            guard let children = try? fm.contentsOfDirectory(atPath: root) else {
                result.failed += 1
                continue
            }
            for child in children {
                let childPath = root + "/" + child
                // A volume mounted inside a cache is not the cache's data: skip
                // it like the sizing walk does. Same family as fence refusals.
                var st = stat()
                if lstat(childPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                   st.st_dev != rootStat.st_dev {
                    result.refused += 1
                    continue
                }
                // removeItem on a symlink deletes the link, not its target.
                do {
                    try fm.removeItem(atPath: childPath)
                    result.removed += 1
                } catch {
                    result.failed += 1
                }
            }
        }
        return result
    }

    /// The full fence, shared by `detect`, `clean` and `CleanupDiscovery` so
    /// they always agree: textual prefix (cheap, fail-closed), a real
    /// non-symlink directory, and a fully-resolved form still strictly inside
    /// the resolved fence. Discovery calls it too — a discovered path gets no
    /// weaker a check than a hand-written one.
    static func passesFence(_ root: String, allowedRoot: String) -> Bool {
        let fence = allowedRoot.hasSuffix("/") ? allowedRoot : allowedRoot + "/"
        return root.hasPrefix(fence) && root != fence && isRealDirectory(root)
            && staysInsideFence(root, allowedRoot: allowedRoot)
    }

    /// uv `link-mode = symlink` makes every virtualenv point INTO the cache:
    /// cleaning it would break all installed packages — uv's own docs say the
    /// same of `uv cache clean`. Checked from the environment and uv's
    /// user-level config; when true, the uv target must not be offered.
    static func uvSymlinkMode(home: String = NSHomeDirectory(),
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["UV_LINK_MODE"] == "symlink" { return true }
        let configDir = environment["XDG_CONFIG_HOME"] ?? (home + "/.config")
        guard let text = try? String(contentsOfFile: configDir + "/uv/uv.toml", encoding: .utf8) else {
            return false
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), trimmed.hasPrefix("link-mode"), trimmed.contains("symlink") {
                return true
            }
        }
        return false
    }

    /// Why this target must not be offered on this machine right now, or nil.
    ///
    /// The whole rule in one place, and injectable, because it is the only
    /// thing standing between the user and a cache emptied underneath the app
    /// that owns it. `CleanupController` uses this as its default; tests drive
    /// it directly rather than needing Chrome to be running.
    static func blockedReason(
        for item: Cleanable, home: String = NSHomeDirectory(),
        isRunning: (String) -> Bool = { appIsRunning($0) }
    ) -> String? {
        // A target whose vendor command is the only viable path is blocked when
        // that command is missing, rather than offered a file removal that would
        // fail on every entry (go-mod). Checked first: it is a property of the
        // target, not of this machine's state.
        if let missing = NativeCleaner.missingRequirement(for: item.id, home: home) {
            return missing
        }
        // The app that owns the files is running: one rule for every app cache,
        // declared on the target rather than special-cased per app.
        if let bundleID = item.ownerBundleID, isRunning(bundleID) {
            let app = item.name
                .replacingOccurrences(of: " cache", with: "")
                .replacingOccurrences(of: " orphaned workspace state", with: "")
            return "\(app) is running — quit it first, or it keeps writing to these files"
        }
        if item.id == "uv", uvSymlinkMode(home: home) {
            return "uv link-mode is \"symlink\" — cleaning would break your virtualenvs"
        }
        return nil
    }

    /// True while the app owning a target is running — the target must not be
    /// offered then.
    ///
    /// This is the difference between an app cache and a package cache, and why
    /// the catalog names apps one by one instead of sweeping every Electron
    /// directory or all of `~/Library/Caches`: a package manager is invoked and
    /// exits, a desktop app holds its cache open for hours. Unlinking
    /// underneath it is not a crash on macOS (the inode outlives the last
    /// close), but the app keeps writing into files nothing can reach any more
    /// — the space is not actually freed until quit, and the cache index can be
    /// left describing entries that no longer exist. Quitting first makes both
    /// go away.
    ///
    /// The counterpart for command-line tools is `ToolActivity`, which warns
    /// rather than blocks: a build that fails can simply be re-run, where a
    /// half-emptied browser cache is a corrupt one.
    ///
    /// Fails closed: when the running-app list cannot be consulted at all, the
    /// target is treated as busy rather than assumed idle.
    static func appIsRunning(_ bundleID: String) -> Bool {
        #if canImport(AppKit)
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID).isEmpty
        #else
        return true
        #endif
    }

    /// True only for a directory that is not itself a symlink (`lstat`, so the
    /// check applies to the entry, not to what it may point at).
    private static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// The textual prefix check can be defeated by a symlinked *intermediate*
    /// component or a `..`: the path still starts with the fence but its real
    /// location is elsewhere. The fully-resolved form must stay strictly inside
    /// the fully-resolved fence for the clean to proceed.
    private static func staysInsideFence(_ root: String, allowedRoot: String) -> Bool {
        let fenceReal = resolvedPath(allowedRoot)
        let fencePrefix = fenceReal.hasSuffix("/") ? fenceReal : fenceReal + "/"
        let real = resolvedPath(root)
        return real != fenceReal && real.hasPrefix(fencePrefix)
    }

    /// Fully-resolved (symlinks + `..`) form of a path.
    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
