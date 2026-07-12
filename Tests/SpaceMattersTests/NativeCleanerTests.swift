import Testing
import Foundation
@testable import SpaceMatters

/// Native cleaner resolution: which targets get one, which binary wins, and
/// the hygiene environment they run under. Execution is never exercised here —
/// the controller seam is tested in `CleanupTests`.
struct NativeCleanerTests {

    @Test func picksTheFirstExistingCandidate() {
        let native = NativeCleaner.available(
            for: "homebrew", home: "/tmp/h",
            isExecutable: { $0 == "/usr/local/bin/brew" })
        #expect(native?.binary == "/usr/local/bin/brew")
        #expect(native?.label == "brew cleanup")
        #expect(native?.arguments == ["cleanup", "-s", "--prune=all"])
    }

    /// npm/pip/yarn… deliberately have no native cleaner (their caches are
    /// designed for plain removal); a known target without its binary has none
    /// either — the file engine is the fallback in both cases.
    @Test func fileEngineTargetsAndMissingBinariesResolveToNil() {
        #expect(NativeCleaner.available(for: "npm", isExecutable: { _ in true }) == nil)
        #expect(NativeCleaner.available(for: "trash", isExecutable: { _ in true }) == nil)
        #expect(NativeCleaner.available(for: "homebrew", isExecutable: { _ in false }) == nil)
    }

    @Test func brewRunsWithHygieneEnvironment() {
        let native = NativeCleaner.available(for: "homebrew", isExecutable: { _ in true })
        #expect(native?.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(native?.environment["HOMEBREW_NO_ANALYTICS"] == "1")
    }

    /// pnpm's standalone install lives under the user's home — the candidate
    /// list must follow the injected home, not the test runner's.
    @Test func pnpmProbesTheHomeShim() {
        let native = NativeCleaner.available(
            for: "pnpm", home: "/Users/x",
            isExecutable: { $0 == "/Users/x/Library/pnpm/pnpm" })
        #expect(native?.binary == "/Users/x/Library/pnpm/pnpm")
        #expect(native?.arguments == ["store", "prune"])
    }
}
