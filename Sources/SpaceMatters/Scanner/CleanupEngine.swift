import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// A known-safe cleanup target for the Low-Hanging Fruits mode: a location whose
/// contents are regenerable by design (package/build caches) or explicitly
/// disposable (the Trash). Paths are absolute; only existing ones are shown.
struct Cleanable: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String
    let icon: String
    /// What deleting costs the user ("re-downloaded on next install", …).
    let note: String
    let paths: [String]
}

/// Catalog, sizing and cleaning for the Low-Hanging Fruits mode.
///
/// Safety model (same spirit as `ScanController.remove`, J4.4):
/// - the catalog is hand-picked — nothing is discovered dynamically;
/// - every operation is fenced inside `allowedRoot` (the user's home), so a
///   mis-built `Cleanable` can never reach outside it;
/// - cleaning deletes the *children* of a cache directory, never the directory
///   itself, and never follows symlinks: a link inside a cache is removed as a
///   link, its target is left untouched; a cache root that *is* a symlink is
///   refused outright rather than resolved.
enum CleanupEngine {

    // MARK: Catalog

    /// Everything here is regenerable: emptying only costs a re-download or a
    /// rebuild. Entries whose paths don't exist are filtered out by `detect`.
    static func catalog(home: String = NSHomeDirectory()) -> [Cleanable] {
        [
            Cleanable(
                id: "trash", name: "Trash", category: "System", icon: "trash.fill",
                note: "Files you already deleted. Emptying is permanent.",
                paths: [home + "/.Trash"]),
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
            Cleanable(
                id: "npm", name: "npm cache", category: "JavaScript", icon: "shippingbox",
                note: "Package tarballs, re-downloaded on next install.",
                paths: [home + "/.npm/_cacache"]),
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
            Cleanable(
                id: "uv", name: "uv cache", category: "Python", icon: "archivebox",
                note: "Package cache, re-fetched on next sync.",
                paths: [home + "/Library/Caches/uv"]),
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
            Cleanable(
                id: "homebrew", name: "Homebrew downloads", category: "Homebrew", icon: "mug.fill",
                note: "Bottle, cask and API downloads, re-fetched on demand.",
                paths: [home + "/Library/Caches/Homebrew"]),
        ]
    }

    /// The catalog restricted to entries with at least one path that passes the
    /// same fence as `clean` (existing real directory, no symlinked root, still
    /// inside `allowedRoot` once resolved). Deciding at detection time keeps the
    /// UI honest: a relocated cache is never shown, sized through its link, and
    /// then refused at cleaning time with gigabytes left on screen.
    static func detect(_ catalog: [Cleanable], allowedRoot: String = NSHomeDirectory()) -> [Cleanable] {
        catalog.compactMap { item in
            let existing = item.paths.filter { passesFence($0, allowedRoot: allowedRoot) }
            guard !existing.isEmpty else { return nil }
            return Cleanable(id: item.id, name: item.name, category: item.category,
                             icon: item.icon, note: item.note, paths: existing)
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

    /// Delete the *children* of each of the item's paths. The paths themselves
    /// survive (tools expect their cache directory to exist). Every path must
    /// live strictly inside `allowedRoot` **once fully resolved** and be a real
    /// directory — a symlinked root, a symlinked *intermediate* component
    /// (`~/.gradle` → an external volume) or a `..` escape are all refused, so
    /// a cache relocated elsewhere is never chased.
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

    /// The full fence, shared by `detect` and `clean` so both always agree:
    /// textual prefix (cheap, fail-closed), a real non-symlink directory, and a
    /// fully-resolved form still strictly inside the resolved fence.
    private static func passesFence(_ root: String, allowedRoot: String) -> Bool {
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

    /// Notion's bundle identifier, and the helpers it spawns under it.
    static let notionBundleID = "notion.id"

    /// True while Notion is running — the target must not be offered then.
    ///
    /// This is the difference between an app cache and a package cache, and why
    /// the catalog names apps one by one instead of sweeping every Electron
    /// directory: a package manager is invoked and exits, a desktop app holds
    /// its cache open for hours. Unlinking underneath it is not a crash on
    /// macOS (the inode outlives the last close), but the service worker keeps
    /// writing into files nothing can reach any more — the space is not
    /// actually freed until quit, and the cache index can be left describing
    /// entries that no longer exist. Quitting first makes both go away.
    ///
    /// Fails closed: when the running-app list cannot be consulted at all, the
    /// target is treated as busy rather than assumed idle.
    static func notionIsRunning() -> Bool {
        #if canImport(AppKit)
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: notionBundleID).isEmpty
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
