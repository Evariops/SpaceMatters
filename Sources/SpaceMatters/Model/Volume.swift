import Foundation
import AppKit
import DiskArbitration

/// A mounted, browsable volume the user can pick from the splash screen.
struct Volume: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isRoot: Bool

    var id: URL { url }
    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    /// The real Finder icon for the volume (computed; not part of identity).
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var kindLabel: String {
        if isRemovable { return "External" }
        if isInternal { return "Internal" }
        return "Volume"
    }

    /// Enumerate every mounted, browsable volume with usable capacity.
    static func mounted() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey,
            .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let daSession = DASessionCreate(kCFAllocatorDefault)

        var result: [Volume] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.volumeIsBrowsable == false { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            if total <= 0 { continue }
            if let daSession, isDiskImage(url, session: daSession) { continue }
            let name = v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent
            result.append(Volume(
                url: url,
                name: name,
                total: total,
                available: Int64(v.volumeAvailableCapacity ?? 0),
                isInternal: v.volumeIsInternal ?? false,
                isRemovable: v.volumeIsRemovable ?? false,
                isRoot: v.volumeIsRootFileSystem ?? false
            ))
        }

        result.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.total > b.total
        }
        return result
    }

    /// True when the volume is backed by a mounted disk image (.dmg).
    /// There is no URLResourceKey for this; DiskArbitration reports such
    /// devices with the model "Disk Image".
    private static func isDiskImage(_ url: URL, session: DASession) -> Bool {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [CFString: Any]
        else { return false }
        return desc[kDADiskDescriptionDeviceModelKey] as? String == "Disk Image"
    }
}
