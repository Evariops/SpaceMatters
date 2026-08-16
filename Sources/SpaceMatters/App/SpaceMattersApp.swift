import SwiftUI
import AppKit

/// Entry point: route to a headless scan when `--scan <path>` is passed,
/// otherwise launch the SwiftUI app.
@main
enum Entry {
    static func main() {
        // Headless subcommands exit with a real status code (0 ok, 1 failure,
        // 2 usage) so scripts can tell a broken run from a clean one — and a
        // subcommand missing its argument prints usage instead of silently
        // falling through to the GUI.
        let args = CommandLine.arguments
        if args.contains("--volumes") {
            HeadlessScan.listVolumes()
            exit(0)
        }
        if args.contains("--containers") {
            exit(HeadlessScan.runContainers())
        }
        if let idx = args.firstIndex(of: "--k8s") {
            let ctx = idx + 1 < args.count ? args[idx + 1] : nil
            exit(HeadlessScan.runK8s(context: ctx))
        }
        if let idx = args.firstIndex(of: "--vm-scan") {
            guard idx + 1 < args.count else {
                print("usage: SpaceMatters --vm-scan <podman|colima> [full|containers]")
                exit(2)
            }
            let scope = idx + 2 < args.count ? args[idx + 2] : "full"
            exit(HeadlessScan.runVM(runtime: args[idx + 1], scope: scope))
        }
        if let idx = args.firstIndex(of: "--mcp") {
            // Defaults to the home directory: it holds the bytes a user can act
            // on, and scanning "/" would spend the session's first minute on
            // system files nobody is allowed to delete anyway.
            let next = idx + 1 < args.count ? args[idx + 1] : nil
            let root = (next?.hasPrefix("-") == false ? next : nil) ?? NSHomeDirectory()
            exit(MCPRelay.run(rootPath: root))
        }
        if let idx = args.firstIndex(of: "--briefing") {
            guard idx + 1 < args.count else {
                print("usage: SpaceMatters --briefing <path> [max-nodes]")
                exit(2)
            }
            let nodes = idx + 2 < args.count ? Int(args[idx + 2]) ?? 300 : 300
            exit(HeadlessScan.runBriefing(path: args[idx + 1], maxNodes: nodes))
        }
        if let idx = args.firstIndex(of: "--scan") {
            exit(HeadlessScan.run(paths: Array(args[(idx + 1)...]))) // empty → usage, exit 2
        }
        SpaceMattersApp.main()
    }
}

struct SpaceMattersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { app.openFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy LLM Briefing") { app.copyBriefing() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!app.canCopyBriefing)
                Button(app.filesystem.verdictCount > 0
                       ? "Clear \(app.filesystem.verdictCount) LLM Verdicts"
                       : "Clear LLM Verdicts") { app.filesystem.clearVerdicts() }
                    .disabled(app.filesystem.verdictCount == 0)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Only the GUI claims the MCP rendezvous socket (SPEC-14 §3.5).
        MCPBridge.shared.enable()

        // `NSToolTipManager` waits a second or more by default, which is fine
        // for a hint and far too slow for a toolbar where the tooltip *is* the
        // documentation. Put in the registration domain, the lowest-priority
        // one, so anybody who has set `NSInitialToolTipDelay` themselves — or
        // globally — still overrides this.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 300])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave no socket file behind: a stale one makes the next `--mcp` try to
        // connect to nothing before falling back, and clutters the support dir.
        MCPBridge.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
