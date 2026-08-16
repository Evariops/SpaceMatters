import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 phase 4 — the setup dialog's command. The dialog shows this string
/// and `apply` runs its arguments, so the two must not drift: a user who copies
/// the displayed command must get exactly what the button would have done.
@MainActor
@Suite struct ClaudeIntegrationTests {

    private func plan(executable: String) -> ClaudeIntegration.Plan {
        ClaudeIntegration.Plan(
            cliPath: nil,
            skillSource: nil,
            skillDestination: URL(fileURLWithPath: "/tmp/skills/space"),
            skillAlreadyInstalled: false,
            skillOutdated: false,
            executablePath: executable)
    }

    /// A skill installed once and never refreshed is how a correction shipped
    /// in the app fails to reach the assistant reading it — the failure this
    /// comparison exists to catch, and one that already happened.
    @Test func aDivergedSkillTreeIsDetected() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("skill-\(UUID().uuidString)")
        let shipped = base.appendingPathComponent("bundle/space")
        let installed = base.appendingPathComponent("home/space")
        for dir in [shipped, installed] {
            try fm.createDirectory(at: dir.appendingPathComponent("references"),
                                   withIntermediateDirectories: true)
            try "procedure".write(to: dir.appendingPathComponent("SKILL.md"),
                                  atomically: true, encoding: .utf8)
            try "podman never shrinks".write(
                to: dir.appendingPathComponent("references/directories.md"),
                atomically: true, encoding: .utf8)
        }
        defer { try? fm.removeItem(at: base) }

        #expect(ClaudeIntegration.treesMatch(shipped, installed))

        // The app ships a correction; the installed copy still says the old
        // thing. That is exactly the drift that must be visible.
        try "podman trims on a weekly timer".write(
            to: shipped.appendingPathComponent("references/directories.md"),
            atomically: true, encoding: .utf8)
        #expect(!ClaudeIntegration.treesMatch(shipped, installed))

        // A file present on one side only counts as drift too.
        try "podman never shrinks".write(
            to: installed.appendingPathComponent("references/directories.md"),
            atomically: true, encoding: .utf8)
        try "extra".write(to: shipped.appendingPathComponent("references/new.md"),
                          atomically: true, encoding: .utf8)
        #expect(!ClaudeIntegration.treesMatch(shipped, installed))

        // A missing tree is drift, not a match — fail towards offering the update.
        #expect(!ClaudeIntegration.treesMatch(shipped, base.appendingPathComponent("absent")))
    }

    @Test func theCommandRegistersAtUserScope() {
        // The CLI defaults to `local`, which is per-directory. A disk analyser
        // has to answer from wherever the session happens to start.
        let command = plan(executable: "/Applications/SpaceMatters.app/Contents/MacOS/SpaceMatters")
            .registerCommand
        #expect(command.contains("mcp add -s user spacematters"))
        #expect(command.hasSuffix("--mcp"))
        // The separator matters: without it the CLI reads `--mcp` as its own flag.
        #expect(command.contains(" -- "))
    }

    @Test func executablePathsWithSpacesAreQuoted() {
        // "/Applications/My Apps/…" is ordinary, and an unquoted copy-pasted
        // command would register a server that can never start.
        let command = plan(executable: "/Applications/My Apps/SpaceMatters.app/Contents/MacOS/SpaceMatters")
            .registerCommand
        #expect(command.contains("\"/Applications/My Apps/SpaceMatters.app/Contents/MacOS/SpaceMatters\""))
    }

    @Test func theSkillShipsInsideTheRepo() throws {
        // The bundle build copies Packaging/skills into Resources; if the skill
        // moved or lost its frontmatter, setup would install something the CLI
        // silently ignores.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = root.appendingPathComponent("Packaging/skills/space/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: space\n"))
        #expect(text.contains("description:"))
        // The procedure the server's own instructions also state — they must agree.
        #expect(text.contains("overview"))
        #expect(text.contains("aged"))
        #expect(text.contains("annotate"))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Packaging/skills/space/references/directories.md").path))
    }
}
