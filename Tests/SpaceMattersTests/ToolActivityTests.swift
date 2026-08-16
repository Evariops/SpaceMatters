import Testing
@testable import SpaceMatters

/// The active-tool warnings behind the cleanup confirmation dialog: the pure
/// classification table, the JVM disambiguation, and a smoke run of the
/// sysctl plumbing (content is machine-dependent, crashing is not).
struct ToolActivityTests {

    @Test func classifiesKnownComms() {
        #expect(ToolActivity.classify(comm: "brew", argv: []).map(\.target) == ["homebrew"])
        #expect(Set(ToolActivity.classify(comm: "Xcode", argv: []).map(\.target))
            == Set(["derived-data", "swiftpm"]))
        #expect(Set(ToolActivity.classify(comm: "go", argv: []).map(\.target))
            == Set(["go-build", "go-mod"]))
        #expect(ToolActivity.classify(comm: "Safari", argv: []).isEmpty)
    }

    @Test func classifiesJVMsByArguments() {
        let daemon = ToolActivity.classify(
            comm: "java",
            argv: ["java", "-Xmx2g", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.7"])
        #expect(daemon.map(\.target) == ["gradle"])
        #expect(daemon.map(\.tool) == ["a Gradle daemon"])

        let maven = ToolActivity.classify(
            comm: "java",
            argv: ["java", "-classpath", "/x", "org.codehaus.plexus.classworlds.launcher.Launcher"])
        #expect(maven.map(\.target) == ["maven"])

        #expect(ToolActivity.classify(comm: "java", argv: ["java", "-jar", "app.jar"]).isEmpty)
    }

    @Test func activeToolsSmoke() {
        _ = ToolActivity.activeTools(for: ["homebrew", "gradle", "npm"])
    }

    /// A build writes the very `bin`/`obj` the artifacts target deletes, so a
    /// running `dotnet` has to warn about both the NuGet cache and the build
    /// output. Pinned because the two are easy to add separately and the gap is
    /// silent: the dialog would simply not mention the build it is about to
    /// break.
    @Test func buildsWarnAboutTheirOwnOutputNotJustTheirCache() {
        #expect(Set(ToolActivity.classify(comm: "dotnet", argv: []).map(\.target))
            == Set(["nuget", "dotnet-artifacts"]))
        #expect(Set(ToolActivity.classify(comm: "msbuild", argv: []).map(\.target))
            == Set(["nuget", "dotnet-artifacts"]))
        #expect(Set(ToolActivity.classify(comm: "cargo", argv: []).map(\.target))
            == Set(["cargo", "cargo-artifacts"]))
    }

    /// Every target that can be offered must be one the warning table knows
    /// about, or the confirmation silently omits the tool it is about to
    /// disrupt. Targets with no plausible command-line owner are listed as
    /// deliberate exemptions, so adding a target forces a decision here.
    @Test func everyOfferableTargetIsCoveredOrDeliberatelyExempt() {
        // App caches gate on `ownerBundleID` instead (a running app blocks the
        // row outright); the Trash and editor state have no build tool at all.
        let exempt: Set<String> = [
            "trash", "notion", "slack", "zoom", "app-updaters",
            "chrome-cache", "firefox-cache", "playwright", "electron",
            "node-gyp", "typescript", "bun",
            "workspace-storage-code", "workspace-storage-code---insiders",
            "workspace-storage-cursor", "workspace-storage-vscodium",
        ]
        let offered = Set(CleanupEngine.catalog().map(\.id))
            .union(["dotnet-artifacts", "cargo-artifacts"])
        let uncovered = offered.subtracting(ToolActivity.coveredTargets).subtracting(exempt)
        #expect(uncovered.isEmpty, "no active-tool warning for: \(uncovered.sorted())")
    }
}
