import Foundation

/// Low-Hanging Fruits in a terminal: the known-safe targets, sized one at a
/// time, emptied only where you ticked them.
///
/// It drives `CleanupController` — the same catalog, the same safety fence,
/// the same vendor cleaners (`brew cleanup`, `go clean -modcache`) and the
/// same `cleanup.jsonl` journal as the window. Nothing is pre-selected, and
/// "select all" deliberately skips the rows whose bytes never come back (the
/// Trash, orphaned editor state): those are ticked one by one or not at all.
struct TUICleanupScreen {

    var state = TUICleanupState()
    private var selectedID: String?
    private var scrollTop = 0
    private var listHeight = 10

    var title: String { "Low-Hanging Fruits" }

    func subtitle(width: Int) -> String {
        switch state.phase {
        case .idle: return "looking for caches and build output…"
        case .sizing: return "measuring \(Format.count(Int64(state.rows.count))) targets — \(Format.bytes(state.totalFound)) so far"
        case .cleaning: return "emptying \(Format.count(Int64(state.selected.count))) targets…"
        case .ready:
            var text = "\(Format.count(Int64(state.rows.count))) targets · \(Format.bytes(state.totalFound)) found"
            if state.totalSelected > 0 { text += " · \(Format.bytes(state.totalSelected)) selected" }
            if state.lastFreed > 0 { text += " · freed \(Format.bytes(state.lastFreed))" }
            if state.lastFailures > 0 { text += " · \(state.lastFailures) could not be removed" }
            return TextCell.fit(text, width)
        }
    }

    var hints: [String] { ["↑↓ move", "space pick", "a all", "⏎ empty", "r refresh", "esc back"] }

    var selected: TUICleanupRow? {
        guard let selectedID else { return state.rows.first }
        return state.rows.first { $0.id == selectedID } ?? state.rows.first
    }

    // MARK: Keys

    mutating func apply(_ key: TerminalKey) -> TUIRequest {
        let rows = state.rows
        let page = max(1, listHeight - 1)
        switch key {
        case .up, .char("k"): move(by: -1, in: rows)
        case .down, .char("j"): move(by: 1, in: rows)
        case .pageUp: move(by: -page, in: rows)
        case .pageDown: move(by: page, in: rows)
        case .home, .char("g"): move(by: -rows.count, in: rows)
        case .end, .char("G"): move(by: rows.count, in: rows)
        case .char(" "), .right, .char("l"):
            if let id = selected?.id { return .toggle(id) }
        case .char("a"): return .toggleAll
        case .enter, .char("c"): return .confirmClean
        case .char("r"): return .reloadCleanup
        case .char("m"): return .menu
        case .char("?"): return .help
        case .escape, .char("q"), .left, .char("h"), .backspace: return .back
        default: break
        }
        return .none
    }

    private mutating func move(by delta: Int, in rows: [TUICleanupRow]) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[min(max(current + delta, 0), rows.count - 1)].id
    }

    // MARK: Rendering

    mutating func body(width: Int, height: Int) -> [String] {
        listHeight = max(0, height)
        let rows = state.rows
        let cursor = rows.firstIndex { $0.id == selectedID } ?? 0

        var lines: [(text: String, kind: Kind)] = []
        var index = 0
        var category: String?
        for row in rows {
            if row.category != category {
                if !lines.isEmpty { lines.append(("", .blank)) }
                lines.append((row.category.uppercased(), .heading))
                category = row.category
            }
            lines.append((line(row, width: width), index == cursor ? .selected : .row(row)))
            index += 1
        }
        if rows.isEmpty {
            lines.append((state.phase == .idle || state.phase == .sizing
                          ? "  looking…" : "  nothing left to empty — the caches are already clear.", .heading))
        }
        if !state.issues.isEmpty {
            lines.append(("", .blank))
            for issue in state.issues.prefix(3) { lines.append(("  ⚠︎ " + issue, .heading)) }
        }

        if let position = lines.firstIndex(where: { $0.kind.isSelected }) {
            if position < scrollTop { scrollTop = position }
            if position >= scrollTop + listHeight { scrollTop = position - listHeight + 1 }
        }
        scrollTop = max(0, min(scrollTop, max(0, lines.count - listHeight)))

        var out: [String] = []
        for line in lines.dropFirst(scrollTop).prefix(listHeight) {
            switch line.kind {
            case .blank: out.append("")
            case .heading: out.append(Style.dim(TextCell.fit(line.text, width)))
            case .selected: out.append(Style.reverse(TextCell.padRight(TextCell.fit(line.text, width), width)))
            case .row(let row):
                let text = TextCell.fit(line.text, width)
                out.append(row.isSelectable ? text : Style.dim(text))
            }
        }
        return out + Array(repeating: "", count: max(0, listHeight - out.count))
    }

    private enum Kind {
        case heading, blank, selected
        case row(TUICleanupRow)

        var isSelected: Bool { if case .selected = self { return true }; return false }
    }

    private func line(_ row: TUICleanupRow, width: Int) -> String {
        let box = row.selected ? "[x]" : (row.isSelectable ? "[ ]" : " · ")
        let size: String
        switch row.size {
        case .pending: size = "…"
        case .sized(let bytes): size = Format.bytes(bytes)
        case .denied: size = "denied"
        case .blocked: size = "blocked"
        }
        var text = "  \(box) " + TextCell.padLeft(size, 10) + "  "
        let nameWidth = width >= 72 ? 28 : 22
        text += TextCell.padRight(TextCell.fit(TextCell.sanitize(row.name), nameWidth), nameWidth)
        // The reason a row cannot be ticked outranks its description: it is the
        // only thing that explains why the bytes are staying.
        var detail: String
        switch row.size {
        case .blocked(let reason): detail = reason
        case .denied: detail = "unreadable — Full Disk Access would let the app size it"
        default: detail = row.note
        }
        if let native = row.nativeLabel { detail = "\(native) · " + detail }
        if !row.regenerable { detail = "not regenerable · " + detail }
        return text + "  " + TextCell.sanitize(detail)
    }
}
