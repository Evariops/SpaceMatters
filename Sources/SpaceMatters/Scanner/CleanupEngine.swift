import Foundation

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
                note: "Content-addressable package store, re-downloaded on demand.",
                paths: [home + "/Library/pnpm/store", home + "/.pnpm-store"]),
            Cleanable(
                id: "nuget", name: "NuGet packages", category: ".NET", icon: "archivebox.fill",
                note: "Global packages + HTTP cache, restored on next build.",
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
                note: "Local artifact repository, re-downloaded on next build.",
                paths: [home + "/.m2/repository"]),
            Cleanable(
                id: "cargo", name: "Cargo registry", category: "Rust & Go", icon: "wrench.and.screwdriver.fill",
                note: "Crate downloads and sources, re-fetched on next build.",
                paths: [home + "/.cargo/registry"]),
            Cleanable(
                id: "go-build", name: "Go build cache", category: "Rust & Go", icon: "wrench.and.screwdriver",
                note: "Compiled build cache, rebuilt on demand.",
                paths: [home + "/Library/Caches/go-build"]),
            Cleanable(
                id: "homebrew", name: "Homebrew downloads", category: "Homebrew", icon: "mug.fill",
                note: "Bottle and formula downloads (what `brew cleanup` removes).",
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

    /// Physical bytes under the item's paths, via the same `getattrlistbulk`
    /// walk as the scanner (symlinks counted as their own size, never followed;
    /// mount points not crossed). Runs off the main thread.
    static func size(of item: Cleanable) -> Measure {
        var total: Int64 = 0
        var openedAny = false
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        for root in item.paths {
            var stack = [root]
            while let dir = stack.popLast() {
                // O_NOFOLLOW: a symlinked root must not be measured through its
                // target (detect refuses it; clean would too), and a directory
                // swapped for a link between enumeration and open is not chased.
                let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard fd >= 0 else { continue }
                if dir == root { openedAny = true }
                let prefix = dir + "/"
                _ = enumerateDirectory(fd: fd, buffer: buffer, bufferSize: bufferSize) { entry in
                    if entry.isDirectory {
                        if entry.isMountPoint { return }
                        let name = String(
                            decoding: UnsafeRawBufferPointer(start: entry.name, count: entry.nameLength),
                            as: UTF8.self
                        )
                        stack.append(prefix + name)
                    } else {
                        total += entry.physicalSize
                    }
                }
                close(fd)
            }
        }
        return openedAny ? .sized(total) : .denied
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
            guard passesFence(root, allowedRoot: allowedRoot) else {
                result.refused += 1
                continue
            }
            var rootStat = stat()
            guard lstat(root, &rootStat) == 0,
                  let children = try? fm.contentsOfDirectory(atPath: root) else {
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

    private static let bufferSize = 256 * 1024
}
