import Foundation

/// A flat list of folders answering a question about the tree: every
/// `node_modules` and their total, the biggest folders anywhere, what nobody
/// has written to in a year.
///
/// The same `TreeQuery` walks the MCP tools and the digest use — a terminal
/// user gets the assistant's questions without an assistant. Results are a
/// snapshot: paths are resolved once, when the query runs, not per frame.
struct TUIResults {

    struct Hit {
        let node: FSNode
        let path: String
    }

    enum Kind {
        case find(pattern: String)
        case top
        case aged(days: Double)

        /// Reads as a sentence with the count in it, because the count is the
        /// answer as often as the list is ("19 folders matching *node_modules*").
        func summary(count: Int) -> String {
            let folders = "\(Format.count(Int64(count))) folder\(count == 1 ? "" : "s")"
            switch self {
            case .find(let pattern):
                return count == 0 ? "nothing matching \(pattern)" : "\(folders) matching \(pattern)"
            case .top:
                return count == 0 ? "no folder in here" : "the \(folders == "1 folder" ? "largest folder" : "\(count) largest folders")"
            case .aged(let days):
                let months = max(1, Int(days / 30))
                return count == 0
                    ? "everything in here was written to within \(months) months"
                    : "\(folders) untouched for \(months) months or more"
            }
        }
    }

    let kind: Kind
    let scope: String
    private(set) var hits: [Hit]
    /// What the whole scan holds — the denominator of the share column.
    let scanTotal: Int64

    private var selectedIndex = 0
    private var scrollTop = 0
    private var listHeight = 10

    init(kind: Kind, scope: String, hits: [Hit], scanTotal: Int64) {
        self.kind = kind
        self.scope = scope
        self.hits = hits
        self.scanTotal = scanTotal
    }

    var total: Int64 { hits.reduce(0) { $0 + $1.node.sizeOnDisk } }

    var target: TUITarget? {
        guard hits.indices.contains(selectedIndex) else { return nil }
        return .folder(hits[selectedIndex].node)
    }

    var title: String {
        switch kind {
        case .find: return "Find"
        case .top: return "Largest"
        case .aged: return "Cold"
        }
    }

    func subtitle(width: Int) -> String {
        var head = kind.summary(count: hits.count)
        if !hits.isEmpty { head += " · \(Format.bytes(total)) between them" }
        return TextCell.fit(head + " · in " + TextCell.sanitize(scope), width)
    }

    var hints: [String] { ["↑↓ move", "⏎ go there", "d Trash", "i info", "esc back", "? help"] }

    /// Drop hits that a delete detached from the tree, and keep the cursor in
    /// range — the list outlives the folders it points at.
    ///
    /// `live` is walked down from the root by the caller rather than tested
    /// through `node.parent` here: `parent` is `unowned`, and a hit whose
    /// *ancestor* was deleted holds the only strong reference left in the
    /// subtree — reading its parent chain would trap on a freed node.
    mutating func keep(_ live: Set<ObjectIdentifier>) {
        hits = hits.filter { live.contains(ObjectIdentifier($0.node)) }
        selectedIndex = min(selectedIndex, max(0, hits.count - 1))
    }

    // MARK: Keys

    mutating func apply(_ key: TerminalKey) -> TUIRequest {
        let page = max(1, listHeight - 1)
        switch key {
        case .up, .char("k"): move(by: -1)
        case .down, .char("j"): move(by: 1)
        case .pageUp: move(by: -page)
        case .pageDown: move(by: page)
        case .home, .char("g"): move(by: -hits.count)
        case .end, .char("G"): move(by: hits.count)
        case .enter, .right, .char("l"):
            if hits.indices.contains(selectedIndex) { return .goTo(hits[selectedIndex].node) }
        case .char("i"): if let target { return .info(target) }
        case .char("o"): if let target { return .reveal(target) }
        case .char("e"): if let target { return .open(target) }
        case .char("d"), .delete: if let target { return .confirmDelete(target, permanently: false) }
        case .char("D"): if let target { return .confirmDelete(target, permanently: true) }
        case .char("m"): return .menu
        case .char("?"): return .help
        case .escape, .char("q"), .left, .char("h"), .backspace: return .back
        default: break
        }
        return .none
    }

    private mutating func move(by delta: Int) {
        guard !hits.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), hits.count - 1)
    }

    // MARK: Rendering

    mutating func body(width: Int, height: Int) -> [String] {
        listHeight = max(0, height - 1)
        let showBar = width >= 50
        let showFiles = width >= 76
        var out = [Style.dim(TextCell.fit(
            TextCell.padLeft("on disk", 10) + "  " + TextCell.padLeft("%", 6)
            + (showBar ? "  " + TextCell.padRight("", 10) : "")
            + (showFiles ? "  " + TextCell.padLeft("files", 11) : "")
            + "  " + TextCell.padLeft("written", 8) + "  path", width))]
        guard listHeight > 0 else { return out }

        if selectedIndex < scrollTop { scrollTop = selectedIndex }
        if selectedIndex >= scrollTop + listHeight { scrollTop = selectedIndex - listHeight + 1 }
        scrollTop = max(0, min(scrollTop, max(0, hits.count - listHeight)))

        for index in hits.indices.dropFirst(scrollTop).prefix(listHeight) {
            let hit = hits[index]
            let bytes = hit.node.sizeOnDisk
            let fraction = scanTotal > 0 ? Double(bytes) / Double(scanTotal) : 0
            let written = hit.node.newestMTime.load(ordering: .relaxed)
            var text = TextCell.padLeft(Format.bytes(bytes), 10)
                + "  " + TextCell.padLeft(String(format: "%.1f%%", fraction * 100), 6)
            if showBar { text += "  " + TextCell.bar(fraction, width: 10) }
            if showFiles { text += "  " + TextCell.padLeft(Format.count(hit.node.fileCount.load(ordering: .relaxed)), 11) }
            text += "  " + TextCell.padLeft(
                written > 0 ? Format.age(Date(timeIntervalSince1970: Double(written))) : "—", 8)
            // The path's tail is the part that identifies the hit.
            let room = max(0, width - TextCell.width(text) - 2)
            text += "  " + TextCell.fitLeading(TextCell.sanitize(hit.path), room)
            let fitted = TextCell.fit(text, width)
            out.append(index == selectedIndex ? Style.reverse(TextCell.padRight(fitted, width)) : fitted)
        }
        if hits.isEmpty {
            out.append(Style.dim(TextCell.fit("  (nothing matched)", width)))
        }
        return out + Array(repeating: "", count: max(0, listHeight + 1 - out.count))
    }
}

/// The one table shape the terminal draws for sources that are not a
/// filesystem tree: Kubernetes volumes, container images. Read-only on
/// purpose — removing an image is `podman`'s job, and the app's container mode
/// is where that is done with its own confirmations.
struct TUITableScreen {

    var table: TUITable?
    let kind: TUITableKind
    private var selectedIndex = 0
    private var scrollTop = 0
    private var listHeight = 10

    init(kind: TUITableKind) {
        self.kind = kind
    }

    var title: String { table?.title ?? "Loading…" }

    func subtitle(width: Int) -> String {
        TextCell.fit(table?.subtitle ?? "querying…", width)
    }

    var hints: [String] { ["↑↓ move", "r refresh", "esc back", "? help"] }

    mutating func apply(_ key: TerminalKey) -> TUIRequest {
        let count = table?.rows.count ?? 0
        let page = max(1, listHeight - 1)
        switch key {
        case .up, .char("k"): move(by: -1, count: count)
        case .down, .char("j"): move(by: 1, count: count)
        case .pageUp: move(by: -page, count: count)
        case .pageDown: move(by: page, count: count)
        case .home, .char("g"): move(by: -count, count: count)
        case .end, .char("G"): move(by: count, count: count)
        case .char("r"): return .reloadTable
        case .char("m"): return .menu
        case .char("?"): return .help
        case .escape, .char("q"), .left, .char("h"), .backspace: return .back
        default: break
        }
        return .none
    }

    private mutating func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    mutating func body(width: Int, height: Int) -> [String] {
        listHeight = max(0, height - 1)
        guard let table else {
            return [Style.dim(TextCell.fit("  querying…", width))]
                + Array(repeating: "", count: max(0, height - 1))
        }
        // Drop the lowest-priority columns until the row fits, as the browser
        // drops its bar and age columns.
        var columns = table.columns
        while width < minimumWidth(columns), let drop = columns.enumerated()
            .filter({ $0.element.priority > 0 })
            .max(by: { $0.element.priority < $1.element.priority })?.offset {
            columns.remove(at: drop)
        }
        let keep = Set(columns.map(\.title))
        let indices = table.columns.enumerated().filter { keep.contains($0.element.title) }.map(\.offset)

        // The bar rides in every row or in none: an aligned header is what
        // makes a column a column.
        let showBar = width >= 64 && table.rows.contains { $0.fraction != nil }
        var out = [Style.dim(TextCell.fit(render(columns.map(\.title), columns: columns,
                                                 fraction: nil, showBar: showBar), width))]
        guard listHeight > 0 else { return out }

        if selectedIndex < scrollTop { scrollTop = selectedIndex }
        if selectedIndex >= scrollTop + listHeight { scrollTop = selectedIndex - listHeight + 1 }
        scrollTop = max(0, min(scrollTop, max(0, table.rows.count - listHeight)))

        for index in table.rows.indices.dropFirst(scrollTop).prefix(listHeight) {
            let row = table.rows[index]
            let cells = indices.compactMap { row.cells.indices.contains($0) ? row.cells[$0] : nil }
            let text = TextCell.fit(render(cells, columns: columns, fraction: row.fraction,
                                           showBar: showBar), width)
            if index == selectedIndex {
                out.append(Style.reverse(TextCell.padRight(text, width)))
            } else {
                out.append(row.dim ? Style.dim(text) : text)
            }
        }
        if table.rows.isEmpty {
            out.append(Style.dim(TextCell.fit("  (nothing to show)", width)))
        }
        if let footnote = table.footnote, out.count < listHeight {
            out.append("")
            out.append(Style.dim(TextCell.fit("  " + footnote, width)))
        }
        return out + Array(repeating: "", count: max(0, listHeight + 1 - out.count))
    }

    private func minimumWidth(_ columns: [TUITable.Column]) -> Int {
        columns.reduce(0) { $0 + max($1.width, TextCell.width($1.title)) + 2 } + 14
    }

    private func render(_ cells: [String], columns: [TUITable.Column],
                        fraction: Double?, showBar: Bool) -> String {
        var text = ""
        for (index, column) in columns.enumerated() {
            let cell = index < cells.count ? TextCell.sanitize(cells[index]) : ""
            if column.width == 0 {
                text += "  " + cell
            } else {
                let fitted = TextCell.fit(cell, column.width)
                text += "  " + (column.alignRight ? TextCell.padLeft(fitted, column.width)
                                                  : TextCell.padRight(fitted, column.width))
            }
            // The bar rides right after the first (size) column, where the eye
            // already is.
            if index == 0, showBar {
                text += "  " + (fraction.map { TextCell.bar($0, width: 8) } ?? String(repeating: " ", count: 8))
            }
        }
        return text
    }
}
