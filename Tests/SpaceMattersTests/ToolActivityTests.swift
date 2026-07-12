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
        #expect(ToolActivity.classify(comm: "go", argv: []).map(\.target) == ["go-build"])
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
}
