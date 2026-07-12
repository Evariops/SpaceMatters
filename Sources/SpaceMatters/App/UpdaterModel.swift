import Combine
import Sparkle
import SwiftUI

/// Sparkle updater, GUI path only (SPEC-12) — never instantiated by the
/// headless subcommands in `Entry`, so CLI runs stay fully offline.
///
/// Owns the `SPUStandardUpdaterController` for the app's lifetime and
/// republishes `canCheckForUpdates` (KVO) for the menu item's enabled state.
/// Consent model: `startingUpdater: true` only *schedules* Sparkle's standard
/// permission prompt (second launch); no network request leaves before the
/// user accepts, and declining keeps automatic checks off for good.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Explicit user request from the menu — allowed even before (or after
    /// declining) the automatic-check consent; that's Sparkle's design.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// "Check for Updates…" menu entry, disabled while a check or an install
/// is already in flight.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
