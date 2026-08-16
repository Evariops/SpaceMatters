import Foundation

/// Read-only queries over a scanned tree, shared by the digest and — from
/// SPEC-14 phase 2 — the MCP tool surface. Pure walks over `FSNode`: no AppKit,
/// no MainActor, no filesystem access.
enum TreeQuery {

    /// **Approximate** file-type breakdown of a subtree.
    ///
    /// Approximate by construction, and it cannot be otherwise: the model keeps
    /// one node per directory and no per-directory extension table — that *is*
    /// the memory design ([FSNode](x-source-tag://FSNode): collapsing files into
    /// their parent is the single biggest RAM win). The only per-directory type
    /// signal that survives a scan is `dominantExt`, so each directory's own-file
    /// bytes are attributed wholly to its dominant extension.
    ///
    /// Across many directories that ranks types correctly; inside one mixed
    /// directory it over-credits the winner. Callers must label the result as an
    /// estimate — only the scan-wide table (`DirectoryScanner.snapshotExtensions`)
    /// is exact, and it cannot be scoped to a subtree.
    static func approximateTypes(of root: FSNode, limit: Int = 15) -> [ExtRow] {
        var totals: [ExtKey: ExtStat] = [:]
        var stack: [FSNode] = [root]
        while let node = stack.popLast() {
            let count = node.directFileCount
            if count > 0 {
                totals[node.dominantExt, default: ExtStat()].merge(
                    ExtStat(logical: node.directFilesLogical,
                            physical: node.directFilesPhysical,
                            count: count))
            }
            stack.append(contentsOf: node.children)
        }
        return totals
            .map { ExtRow(key: $0.key, name: $0.key.displayName,
                          logical: $0.value.logical, physical: $0.value.physical,
                          count: $0.value.count) }
            .sorted { $0.physical > $1.physical }
            .prefix(limit)
            .map { $0 }
    }

    /// How long ago the subtree was last written, in days. `nil` when unknown —
    /// a streamed VM/SSH scan carries no timestamps, and reporting "56 years"
    /// for a missing attribute is the one answer worse than reporting nothing.
    static func ageInDays(of node: FSNode, now: Date = Date()) -> Double? {
        guard let written = node.newestWrite else { return nil }
        return max(0, now.timeIntervalSince(written) / 86_400)
    }
}
