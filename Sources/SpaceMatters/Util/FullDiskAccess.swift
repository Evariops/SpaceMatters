import Foundation
import AppKit

/// Full Disk Access is the only macOS permission that grants blanket read access
/// to protected locations (Photos, Mail, Music media, Time Machine, other users'
/// data…) with a *single* manual grant — instead of one TCC prompt per category.
/// We can't request it programmatically, but we can detect it and deep-link to
/// the right Settings pane.
enum FullDiskAccess {
    /// These locations are gated behind Full Disk Access. TCC reliably intercepts
    /// `open()` (unlike `access()`, which can give stale results), so a successful
    /// open means FDA is active. None of these trigger a prompt.
    static var isGranted: Bool {
        let home = NSHomeDirectory()
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Safari/CloudTabs.db",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        // Directory traversal of the TCC folder also requires FDA.
        let dirFD = open(home + "/Library/Application Support/com.apple.TCC", O_RDONLY | O_DIRECTORY)
        if dirFD >= 0 { close(dirFD); return true }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// TCC changes don't apply to an already-running process, so offer a relaunch.
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
