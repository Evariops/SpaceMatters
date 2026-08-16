import Foundation
import AppKit

/// One-click setup for the Claude integration — SPEC-14 phase 4.
///
/// Two halves that are useless apart: the MCP server is the data, the skill is
/// the method (procedure, how to read the numbers, and the directory knowledge a
/// model cannot infer from bytes and dates).
///
/// Nothing is written before the user has read exactly what will be written.
/// Registration goes through `claude mcp add` rather than editing the CLI's own
/// config file: that file is the CLI's business, its shape can change, and a
/// GUI app rewriting it is how someone loses their MCP setup.
@MainActor
enum ClaudeIntegration {

    nonisolated static let serverName = "spacematters"

    struct Plan {
        /// `nil` when the CLI could not be found — the skill can still be
        /// installed and the command still shown for the user to run themselves.
        var cliPath: String?
        var skillSource: URL?
        var skillDestination: URL
        var skillAlreadyInstalled: Bool
        var executablePath: String

        var registerCommand: String {
            "claude mcp add -s user \(serverName) -- \"\(executablePath)\" --mcp"
        }
    }

    /// GUI apps inherit a minimal `PATH`, so `claude` is looked for where it
    /// actually installs rather than resolved through the shell.
    private static let cliCandidates = [
        NSHomeDirectory() + "/.local/bin/claude",
        NSHomeDirectory() + "/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static func plan() -> Plan {
        let destination = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/skills/space")
        return Plan(
            cliPath: cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) },
            skillSource: Bundle.main.url(forResource: "space", withExtension: nil,
                                         subdirectory: "skills"),
            skillDestination: destination,
            skillAlreadyInstalled: FileManager.default.fileExists(atPath: destination.path),
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }


    /// Is the server already registered? Asks the CLI rather than parsing its
    /// config file — that file is the CLI's business and its shape can change.
    /// Short timeout: this only decorates a popover, it must never hang one.
    static func isRegistered(_ plan: Plan) async -> Bool {
        guard let cli = plan.cliPath else { return false }
        let result = await ProcessRunner.run(cli, ["mcp", "list"], timeout: 10)
        return result.exitCode == 0 && result.stdoutString.contains(serverName + ":")
    }

    // MARK: Doing it

    enum Outcome {
        case done(registered: Bool)
        case failed(String)
    }

    static func apply(_ plan: Plan) -> Outcome {
        if let source = plan.skillSource {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: plan.skillDestination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: plan.skillDestination.path) {
                    try fm.removeItem(at: plan.skillDestination)
                }
                try fm.copyItem(at: source, to: plan.skillDestination)
            } catch {
                return .failed("Could not install the skill: \(error.localizedDescription)")
            }
        }

        guard let cli = plan.cliPath else { return .done(registered: false) }
        let result = ProcessRunner.runSync(
            cli, ["mcp", "add", "-s", "user", serverName, "--", plan.executablePath, "--mcp"],
            timeout: 30)
        guard result.exitCode == 0 else {
            // Report what the CLI actually said — an "already exists" is a very
            // different problem from a broken install, and guessing which would
            // send the user down the wrong path.
            let detail = [result.stderrString, result.stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit code \(result.exitCode)"
            return .failed("The skill is installed, but registering the server failed:\n\n\(detail)"
                + "\n\nRun this yourself to see more:\n    \(plan.registerCommand)")
        }
        return .done(registered: true)
    }

}
