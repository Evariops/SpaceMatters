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

    // MARK: Path ↔ node

    /// Path mapping for a single-seed scan (`--mcp`, `--briefing`). The GUI has
    /// its own multi-seed version on `ScanController`; this one needs no seed map
    /// because there is exactly one root, which also makes the fence trivial:
    /// anything that doesn't resolve *through* the root doesn't resolve at all.
    struct Index {
        let root: FSNode
        let rootPath: String

        func path(of node: FSNode) -> String {
            var components: [String] = []
            var current: FSNode? = node
            while let n = current, n !== root {
                components.append(n.name)
                current = n.parent
            }
            guard !components.isEmpty else { return rootPath }
            let tail = components.reversed().joined(separator: "/")
            return rootPath == "/" ? "/" + tail : rootPath + "/" + tail
        }

        /// `nil` for anything outside the scan — never a silent re-scan, and
        /// never a walk of the real filesystem.
        func node(at path: String) -> FSNode? {
            let target = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
            if target == rootPath || target.isEmpty || target == "." { return root }
            let base = rootPath == "/" ? "/" : rootPath + "/"
            let relative: Substring
            if target.hasPrefix(base) {
                relative = target.dropFirst(base.count)
            } else if !target.hasPrefix("/") {
                relative = Substring(target) // accept paths relative to the root
            } else {
                return nil
            }
            var node = root
            for component in relative.split(separator: "/") where component != "." {
                guard let child = node.children.first(where: { $0.name == component }) else { return nil }
                node = child
            }
            return node
        }
    }

    // MARK: Rankings

    /// Every directory in the subtree, largest first.
    static func top(of root: FSNode, limit: Int, minBytes: Int64 = 0) -> [FSNode] {
        var all: [FSNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            let kids = node.children
            stack.append(contentsOf: kids)
            if node !== root, node.sizeOnDisk >= minBytes { all.append(node) }
        }
        return Array(all.sorted { $0.sizeOnDisk > $1.sizeOnDisk }.prefix(limit))
    }

    /// Directories whose name matches a shell glob, **without descending into a
    /// match**. Nested hits (`node_modules/x/node_modules`) would otherwise be
    /// counted twice in the total, which is precisely the number this exists to
    /// produce: "340 node_modules, 22 GiB between them".
    static func find(in root: FSNode, pattern: String, minBytes: Int64 = 0) -> [FSNode] {
        var matches: [FSNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node !== root, fnmatch(pattern, node.name, 0) == 0 {
                if node.sizeOnDisk >= minBytes { matches.append(node) }
                continue // do not descend: a nested match is already inside this one
            }
            stack.append(contentsOf: node.children)
        }
        return matches.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
    }

    /// Subtrees untouched for at least `days`, **shallowest first**: once a
    /// folder is cold every folder inside it is too, so reporting the outermost
    /// one and stopping is both the shorter answer and the actionable one.
    static func aged(in root: FSNode, olderThanDays days: Double,
                     minBytes: Int64, now: Date = Date()) -> [FSNode] {
        var matches: [FSNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node !== root, let age = ageInDays(of: node, now: now), age >= days {
                if node.sizeOnDisk >= minBytes { matches.append(node) }
                continue
            }
            stack.append(contentsOf: node.children)
        }
        return matches.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
    }

    // MARK: Parsing

    /// `500M`, `2GiB`, `1.5g`, `1024` — sizes as a human types them.
    static func parseBytes(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0 else { return nil }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit.first {
        case nil: multiplier = 1
        case "k": multiplier = 1024
        case "m": multiplier = 1024 * 1024
        case "g": multiplier = 1024 * 1024 * 1024
        case "t": multiplier = 1024 * 1024 * 1024 * 1024
        case "b" where unit == "b": multiplier = 1
        default: return nil
        }
        return Int64(value * multiplier)
    }

    /// `90d`, `6mo`, `1y`, `18m` (months) — durations as a human types them.
    static func parseDays(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0 else { return nil }
        switch trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "d", "day", "days": return value
        case "w", "week", "weeks": return value * 7
        // "m" is months here, not minutes: nothing in a disk analyser is measured
        // in minutes, and "6m" overwhelmingly means half a year.
        case "m", "mo", "month", "months": return value * 30.44
        case "y", "yr", "year", "years": return value * 365.25
        default: return nil
        }
    }
}
