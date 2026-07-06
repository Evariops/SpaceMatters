import Darwin
import Foundation

enum MountInfo {
    /// Mount points of non-local (network) filesystems. We skip these while
    /// traversing a local disk: they trigger the "network volume" TCC prompt,
    /// are slow, and don't represent the disk's own usage.
    static func networkMountPoints() -> Set<String> {
        var bufferPtr: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&bufferPtr, MNT_NOWAIT)
        guard count > 0, let buffer = bufferPtr else { return [] }

        var result = Set<String>()
        for i in 0..<Int(count) {
            let fs = buffer[i]
            let isLocal = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
            guard !isLocal else { continue }
            let path = withUnsafePointer(to: fs.f_mntonname) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            result.insert(path)
        }
        return result
    }
}
