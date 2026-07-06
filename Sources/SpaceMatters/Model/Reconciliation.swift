import Foundation

/// Explains the gap between what SpaceMatters scanned and the "used" space the OS
/// reports for a volume (finding J9 — "why doesn't this match Finder/df?").
///
/// Every figure is an honest best-effort. `unaccounted` is whatever's left after
/// the parts we can measure (another user's data, filesystem metadata, overhead).
/// When the scan alone already exceeds "used", that's the signature of attribution
/// mode counting hardlinks/clones several times — surfaced as `scanExceedsUsed`.
struct Reconciliation: Equatable {
    let volumeUsed: Int64        // total − available, the OS's "used"
    let scanned: Int64           // our measured on-disk total
    let trash: Int64             // ~/.Trash + this volume's .Trashes
    let purgeable: Int64         // reclaimable: local snapshots, caches (Apple's estimate)
    let snapshotCount: Int       // local APFS / Time Machine snapshots
    let skippedPaths: Int64      // paths the scan couldn't read (permissions/errors)

    var accountedFor: Int64 { scanned + trash + purgeable }
    var unaccounted: Int64 { max(0, volumeUsed - accountedFor) }
    var scanExceedsUsed: Bool { scanned > volumeUsed }

    /// Gather the breakdown (walks the Trash and shells out to `tmutil`). Blocking
    /// — call it from a detached task (see `ReconciliationButton`). Returns `nil`
    /// if the volume's capacity can't be read.
    static func compute(volumeURL: URL, scannedPhysical: Int64, skippedPaths: Int64) -> Reconciliation? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let vals = try? volumeURL.resourceValues(forKeys: keys),
              let totalCapacity = vals.volumeTotalCapacity else { return nil }
        let total = Int64(totalCapacity)
        let available = Int64(vals.volumeAvailableCapacity ?? 0)
        // NB: this key returns Int64? (the others are Int?).
        let importantAvailable: Int64 = vals.volumeAvailableCapacityForImportantUsage ?? available
        let used = max(0, total - available)
        // Purgeable ≈ the extra room the OS could free for "important" use beyond
        // plain free space (local snapshots, caches).
        let purgeable = max(0, importantAvailable - available)

        return Reconciliation(
            volumeUsed: used,
            scanned: scannedPhysical,
            trash: trashSize(volumeURL: volumeURL),
            purgeable: purgeable,
            snapshotCount: snapshotCount(volumeURL: volumeURL),
            skippedPaths: skippedPaths
        )
    }

    private static func trashSize(volumeURL: URL) -> Int64 {
        var total: Int64 = 0
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
            volumeURL.appendingPathComponent(".Trashes/\(getuid())"),
        ]
        for dir in candidates {
            guard let e = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                options: [], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func snapshotCount(volumeURL: URL) -> Int {
        let r = ProcessRunner.runSync("/usr/bin/tmutil", ["listlocalsnapshots", volumeURL.path], timeout: 8)
        guard r.ok else { return 0 }
        return r.stdoutString.split(separator: "\n").filter { $0.contains("com.apple") }.count
    }
}
