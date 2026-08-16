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
            executablePath: executable)
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
