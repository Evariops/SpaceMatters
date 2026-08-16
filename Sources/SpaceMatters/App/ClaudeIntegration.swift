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
        /// The installed skill differs from the one in this build.
        ///
        /// Treating "the directory exists" as "the skill is current" is how a
        /// correction shipped in the app never reaches the assistant reading
        /// it: the install runs once, and every later version of the guidance
        /// stays in the bundle. The failure is silent and it is the worst kind
        /// — the model keeps answering confidently from advice we already knew
        /// was wrong.
        var skillOutdated: Bool
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
        let source = Bundle.main.url(forResource: "space", withExtension: nil,
                                     subdirectory: "skills")
        let installed = FileManager.default.fileExists(atPath: destination.path)
        return Plan(
            cliPath: cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0) },
            skillSource: source,
            skillDestination: destination,
            skillAlreadyInstalled: installed,
            skillOutdated: installed && source.map {
                !treesMatch($0, destination)
            } ?? false,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    /// Whether two skill directories hold the same files with the same bytes.
    ///
    /// A content comparison rather than a version number, because the thing that
    /// matters is whether the assistant is reading what this build says — and
    /// because it also catches a hand-edited copy, which is a reason to ask
    /// before overwriting rather than a reason to overwrite. The tree is a
    /// handful of small Markdown files, so reading it whole costs nothing.
    /// Anything unreadable counts as a mismatch: fail towards offering the
    /// update, never towards silently keeping stale guidance.
    static func treesMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        func files(_ root: URL) -> [String: Data]? {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
            var out: [String: Data] = [:]
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                // Finder metadata is not content and must not force an update.
                if url.lastPathComponent == ".DS_Store" { continue }
                guard let data = try? Data(contentsOf: url) else { return nil }
                out[url.path.replacingOccurrences(of: root.path, with: "")] = data
            }
            return out
        }
        guard let left = files(lhs), let right = files(rhs) else { return false }
        return left == right
    }

    /// Is the server registered at user scope?
    ///
    /// Read from the config rather than asked of `claude mcp list`: that command
    /// *health-checks every server the user has*, including remote ones over the
    /// network, which took seconds of spinner to answer a question about one
    /// local entry. Reading is also safe in a way writing is not — registration
    /// still goes through the CLI, because that is the half that must survive a
    /// format change.
    nonisolated static func isRegistered() -> Bool {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
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
