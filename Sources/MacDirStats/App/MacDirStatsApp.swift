import SwiftUI
import AppKit

/// Entry point: route to a headless scan when `--scan <path>` is passed,
/// otherwise launch the SwiftUI app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--volumes") {
            HeadlessScan.listVolumes()
            return
        }
        if let idx = args.firstIndex(of: "--scan"), idx + 1 < args.count {
            HeadlessScan.run(paths: Array(args[(idx + 1)...]))
            return
        }
        MacDirStatsApp.main()
    }
}

struct MacDirStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = ScanController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { controller.chooseFolderAndScan() }
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
