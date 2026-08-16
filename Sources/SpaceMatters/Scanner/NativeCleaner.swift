import Foundation

/// The vendor's own cleaner for a cleanup target, preferred over file removal
/// when its binary is installed — the tool brings semantics a file walk cannot
/// have. Homebrew coordinates through its own locks, so a concurrent `brew`
/// fails cleanly instead of losing an app mid-`upgrade --cask`; `pnpm store
/// prune` removes only packages no project references; `dotnet` and `go`
/// resolve their own configured cache locations, env overrides included.
///
/// When a native run fails, nothing falls back to file removal in the same
/// pass: the failure may be exactly the vendor's lock doing its job, and
/// deleting the files underneath it would recreate the race the native path
/// exists to close.
struct NativeCleaner: Sendable, Equatable {
    let binary: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    /// Display name shown in the row and the journal ("brew cleanup").
    let label: String

    /// Targets whose vendor command is not a preference but the *only* viable
    /// path, mapped to the reason shown when its binary is missing.
    ///
    /// Go extracts every module into a tree it then marks read-only (`0555`,
    /// deepest first). Unlinking an entry needs write permission on its parent
    /// *directory*, not on the entry, so file removal returns EACCES on every
    /// module — `rm -rf` fails the same way, which is why `go clean -modcache`
    /// exists. Offering the target without the toolchain would walk 15 GB and
    /// free nothing, reporting a wall of failures.
    static let nativeRequired: [String: String] = [
        "go-mod": "needs the Go toolchain — Go marks module files read-only, "
            + "only `go clean -modcache` can empty the cache",
    ]

    /// The reason a *native-required* target cannot run here, or nil when it
    /// can (or when the target has no such requirement). Drives `blockedReason`
    /// in `CleanupController`, so the row is shown and explained rather than
    /// silently offering a clean that would fail on every file.
    static func missingRequirement(
        for targetID: String, home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        guard let reason = nativeRequired[targetID] else { return nil }
        return available(for: targetID, home: home, isExecutable: isExecutable) == nil ? reason : nil
    }

    /// The native cleaner for a catalog target, when its binary exists.
    /// Candidates are fixed absolute paths: a GUI app inherits no shell PATH,
    /// and probing the known install prefixes beats guessing an environment.
    /// Targets deliberately absent (npm, pip, yarn…) gain nothing from their
    /// vendor command — their caches are designed for plain removal.
    static func available(
        for targetID: String, home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> NativeCleaner? {
        guard let spec = specs(home: home)[targetID],
              let binary = spec.candidates.first(where: isExecutable) else { return nil }
        return NativeCleaner(binary: binary, arguments: spec.arguments,
                             environment: spec.environment, timeout: spec.timeout,
                             label: spec.label)
    }

    private struct Spec {
        let candidates: [String]
        let arguments: [String]
        let environment: [String: String]
        let timeout: TimeInterval
        let label: String
    }

    /// Cleaning tens of gigabytes can be legitimately slow — same 10 min
    /// deadline as the container actions, watchdog-killed past that.
    private static func specs(home: String) -> [String: Spec] {
        [
            "homebrew": Spec(
                candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                arguments: ["cleanup", "-s", "--prune=all"],
                // Hygiene: a cleaner must not update taps or phone home.
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1",
                              "HOMEBREW_NO_ANALYTICS": "1",
                              "HOMEBREW_NO_ENV_HINTS": "1"],
                timeout: 600, label: "brew cleanup"),
            "pnpm": Spec(
                candidates: [home + "/Library/pnpm/pnpm",
                             "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"],
                arguments: ["store", "prune"],
                environment: [:], timeout: 600, label: "pnpm store prune"),
            "nuget": Spec(
                candidates: ["/usr/local/share/dotnet/dotnet",
                             "/opt/homebrew/bin/dotnet", "/usr/local/bin/dotnet"],
                arguments: ["nuget", "locals", "all", "--clear"],
                environment: [:], timeout: 600, label: "dotnet nuget locals --clear"),
            "go-build": Spec(
                candidates: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go",
                             "/usr/local/bin/go"],
                arguments: ["clean", "-cache"],
                environment: [:], timeout: 600, label: "go clean -cache"),
            // Not an optimization — see `nativeRequired`. Removes the module
            // cache root outright (like `dotnet nuget locals`), which sizing
            // and detection already treat as "empty", not as an error.
            "go-mod": Spec(
                candidates: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go",
                             "/usr/local/bin/go"],
                arguments: ["clean", "-modcache"],
                environment: [:], timeout: 600, label: "go clean -modcache"),
        ]
    }
}
