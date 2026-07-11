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
        if let idx = args.firstIndex(of: "--scan") {
            exit(HeadlessScan.run(paths: Array(args[(idx + 1)...]))) // empty → usage, exit 2
        }
        SpaceMattersApp.main()
    }
}

struct SpaceMattersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

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
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
