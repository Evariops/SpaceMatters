import Foundation

/// State and rendering of the terminal browser (`--tui`, SPEC-15).
///
/// Pure over `FSNode` and scalars, like `TreeDigest`: no file descriptor, no
/// escape sequence written anywhere — `render` returns the frame as lines, so
/// every screen the browser can draw is a value a test can compare. The
/// terminal plumbing lives in [Terminal](x-source-tag://Terminal).
///
/// Read-only by design. Deleting stays in the app's cleanup pass, which is
/// fenced and journalled; a keystroke in a terminal is not.
struct TUIBrowser {

    /// One line of the listing: a sub-folder, or the folder's own files rolled
    /// into a single row — the same aggregate the tree keeps (files are never
    /// nodes, see `FSNode`).
    enum Row: Equatable {
        case folder(FSNode)
        case ownFiles(count: Int64, bytes: Int64)
    }

    /// What the scan is doing, sampled by the caller once per frame.
    struct Status {
        var scanning: Bool
        var elapsed: TimeInterval
        var files: Int64
        var folders: Int64
        var skipped: Int64
        /// Scan-wide, exact (`DirectoryScanner.snapshotExtensions`). Only read
        /// while the types view is shown.
        var types: [ExtRow] = []
    }

    /// The selection follows a *node*, not an index: sizes keep moving while
    /// the scan runs, rows re-sort ten times a second, and a highlight pinned to
    /// "row 3" would slide onto another folder under the user's cursor.
    private enum Selection: Equatable {
        case folder(FSNode)
        case ownFiles
    }

    let root: FSNode
    let rootPath: String
    /// Root first, current folder last. Never empty.
    private(set) var trail: [FSNode]
    private(set) var showTypes = false
    private var selection: Selection?
    private var scrollTop = 0
    /// Rows the last frame had room for — what a page key moves by.
    private var listHeight = 10

    init(root: FSNode, rootPath: String) {
        self.root = root
        self.rootPath = rootPath
        self.trail = [root]
    }

    var current: FSNode { trail[trail.count - 1] }

    var currentPath: String {
        let tail = trail.dropFirst().map(\.name)
        guard !tail.isEmpty else { return rootPath }
        return (rootPath == "/" ? "" : rootPath) + "/" + tail.joined(separator: "/")
    }

    // MARK: Rows

    /// Sub-folders largest first, own files ranked among them by size — the
    /// order the digest uses, so both read the same way.
    func rows() -> [Row] {
        let node = current
        // Sizes are sampled once: the atomics keep moving under a live scan, and
        // a comparator that reads them twice can disagree with itself.
        let sized = node.children
            .map { (node: $0, bytes: $0.sizeOnDisk) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.node.name < $1.node.name }
        var rows = sized.map { Row.folder($0.node) }
        let count = node.directFileCount
        if count > 0 {
            let bytes = node.directFilesPhysical
            let at = sized.firstIndex { $0.bytes < bytes } ?? sized.count
            rows.insert(.ownFiles(count: count, bytes: bytes), at: at)
        }
        return rows
    }

    private func selectedIndex(in rows: [Row]) -> Int {
        guard let selection else { return 0 }
        return rows.firstIndex { row in
            switch (row, selection) {
            case (.folder(let a), .folder(let b)): return a === b
            case (.ownFiles, .ownFiles): return true
            default: return false
            }
        } ?? 0
    }

    private mutating func select(_ row: Row) {
        switch row {
        case .folder(let node): selection = .folder(node)
        case .ownFiles: selection = .ownFiles
        }
    }

    // MARK: Keys

    /// Applies one key. Returns `false` when the browser should close.
    mutating func apply(_ key: TerminalKey) -> Bool {
        switch key {
        case .interrupt, .char("q"):
            return false
        default:
            break
        }
        if showTypes {
            switch key {
            case .char("t"), .left, .char("h"), .backspace, .escape: showTypes = false
            default: break
            }
            return true
        }
        let rows = self.rows()
        let page = max(1, listHeight - 1)
        switch key {
        case .up, .char("k"): move(by: -1, in: rows)
        case .down, .char("j"): move(by: 1, in: rows)
        case .pageUp: move(by: -page, in: rows)
        case .pageDown: move(by: page, in: rows)
        case .home, .char("g"): move(by: -rows.count, in: rows)
        case .end, .char("G"): move(by: rows.count, in: rows)
        case .enter, .right, .char("l"): open(in: rows)
        case .left, .char("h"), .backspace: back()
        case .char("t"): showTypes = true
        default: break
        }
        return true
    }

    private mutating func move(by delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        let index = min(max(selectedIndex(in: rows) + delta, 0), rows.count - 1)
        select(rows[index])
    }

    private mutating func open(in rows: [Row]) {
        guard !rows.isEmpty, case .folder(let node) = rows[selectedIndex(in: rows)] else { return }
        trail.append(node)
        selection = nil
        scrollTop = 0
    }

    /// Up one level, landing on the folder just left — so ← then → is a no-op.
    private mutating func back() {
        guard trail.count > 1 else { return }
        selection = .folder(trail.removeLast())
        scrollTop = 0
    }

    // MARK: Rendering

    /// Exactly `height` lines, none wider than `width` cells once its SGR
    /// sequences (bold, dim, reverse — no colour) are set aside.
    mutating func render(width: Int, height: Int, status: Status) -> [String] {
        let width = max(width, 1)
        listHeight = max(0, height - 4)

        var lines = [header(status: status, width: width), location(width: width)]
        if showTypes {
            lines += typesBody(status: status, width: width)
        } else {
            lines += listBody(width: width)
        }
        lines.append(dim(TextCell.fit(footer, width)))
        return Array(lines.prefix(max(height, 0)))
    }

    private func header(status: Status, width: Int) -> String {
        var facts = status.scanning
            ? String(format: "scanning… %.1f s", status.elapsed)
            : String(format: "scanned in %.1f s", status.elapsed)
        facts += " · \(Format.count(status.files)) files · \(Format.count(status.folders)) folders"
        if status.skipped > 0 { facts += " · \(Format.count(status.skipped)) unreadable, skipped" }
        let title = "SpaceMatters"
        guard width > TextCell.width(title) else { return bold(TextCell.fit(title, width)) }
        return bold(title) + TextCell.fit("  " + facts, width - TextCell.width(title))
    }

    private func location(width: Int) -> String {
        let node = current
        var facts = "\(Format.bytes(node.sizeOnDisk)) on disk · \(Format.count(node.fileCount.load(ordering: .relaxed))) files"
        if let divergence = node.divergence { facts += " · \(divergence.label)" }
        // Keep the facts and cut the path from the left: its end is the part
        // that says where you are.
        let suffix = "  " + facts
        let room = width - TextCell.width(suffix)
        let path = TextCell.sanitize(currentPath)
        guard room >= 8 else { return TextCell.fit(path + suffix, width) }
        return TextCell.fitLeading(path, room) + suffix
    }

    private struct Columns {
        let bar: Int
        let files: Bool
        let age: Bool

        init(width: Int) {
            bar = width >= 50 ? 10 : 0
            age = width >= 64
            files = width >= 76
        }
    }

    private func line(size: String, percent: String, bar: String, files: String, age: String,
                      name: String, columns: Columns) -> String {
        var s = TextCell.padLeft(size, 10) + "  " + TextCell.padLeft(percent, 6)
        if columns.bar > 0 { s += "  " + TextCell.padRight(bar, columns.bar) }
        if columns.files { s += "  " + TextCell.padLeft(files, 11) }
        if columns.age { s += "  " + TextCell.padLeft(age, 8) }
        return s + "  " + name
    }

    private mutating func listBody(width: Int) -> [String] {
        let columns = Columns(width: width)
        var out = [dim(TextCell.fit(line(size: "on disk", percent: "%", bar: "", files: "files",
                                         age: "written", name: "name", columns: columns), width))]
        guard listHeight > 0 else { return out }

        let rows = self.rows()
        let selected = rows.isEmpty ? 0 : selectedIndex(in: rows)
        if selected < scrollTop { scrollTop = selected }
        if selected >= scrollTop + listHeight { scrollTop = selected - listHeight + 1 }
        scrollTop = max(0, min(scrollTop, rows.count - listHeight))

        let total = current.sizeOnDisk
        for index in rows.indices.dropFirst(scrollTop).prefix(listHeight) {
            let text = TextCell.fit(describe(rows[index], total: total, columns: columns), width)
            out.append(index == selected ? reverse(TextCell.padRight(text, width)) : text)
        }
        if rows.isEmpty {
            out.append(dim(TextCell.fit(current.isScanned ? "  (no files)" : "  (scanning…)", width)))
        }
        return padded(out, to: listHeight + 1)
    }

    private func describe(_ row: Row, total: Int64, columns: Columns) -> String {
        let bytes: Int64, files: Int64, written: Int64, name: String
        switch row {
        case .folder(let node):
            bytes = node.sizeOnDisk
            files = node.fileCount.load(ordering: .relaxed)
            written = node.newestMTime.load(ordering: .relaxed)
            // A trailing "…" marks a folder no worker has read yet: its row is
            // a placeholder that will fill in, not a small folder.
            name = TextCell.sanitize(node.name) + "/" + (node.isScanned ? "" : " …")
        case .ownFiles(let count, let size):
            bytes = size
            files = count
            written = current.directNewestMTime
            name = "[\(Format.count(count)) files here]"
        }
        let fraction = total > 0 ? Double(bytes) / Double(total) : 0
        // 0 means unknown (streamed scans carry no timestamps) — never 1970.
        let age = written > 0 ? Format.age(Date(timeIntervalSince1970: Double(written))) : "—"
        return line(size: Format.bytes(bytes), percent: String(format: "%.1f%%", fraction * 100),
                    bar: TextCell.bar(fraction, width: columns.bar), files: Format.count(files),
                    age: age, name: name, columns: columns)
    }

    private func typesBody(status: Status, width: Int) -> [String] {
        let showBar = width >= 50
        var out = [dim(TextCell.fit("file types — whole scan, exact", width))]
        let total = root.sizeOnDisk
        for row in status.types.prefix(listHeight) {
            let fraction = total > 0 ? Double(row.physical) / Double(total) : 0
            var s = TextCell.padLeft(Format.bytes(row.physical), 10)
                + "  " + TextCell.padLeft(String(format: "%.1f%%", fraction * 100), 6)
            if showBar { s += "  " + TextCell.bar(fraction, width: 10) }
            s += "  " + TextCell.padLeft(Format.count(row.count), 11) + "  " + TextCell.sanitize(row.name)
            out.append(TextCell.fit(s, width))
        }
        return padded(out, to: listHeight + 1)
    }

    private var footer: String {
        showTypes
            ? "t/← back to folders   q quit"
            : "↑↓ move   →/⏎ open   ←/⌫ up   t file types   q quit"
    }

    private func padded(_ lines: [String], to count: Int) -> [String] {
        lines.count >= count ? Array(lines.prefix(count)) : lines + Array(repeating: "", count: count - lines.count)
    }

    private func bold(_ s: String) -> String { "\u{1B}[1m" + s + "\u{1B}[0m" }
    private func dim(_ s: String) -> String { "\u{1B}[2m" + s + "\u{1B}[0m" }
    private func reverse(_ s: String) -> String { "\u{1B}[7m" + s + "\u{1B}[0m" }
}

/// Fitting text into terminal cells. A `Character` count is not a width: CJK
/// and emoji take two cells, combining marks none — and a name drawn one cell
/// too wide wraps and shears every line below it.
enum TextCell {

    /// File names are untrusted bytes: one carrying an escape sequence would
    /// otherwise *drive* the terminal it is printed on. Control and format
    /// characters are dropped, as the digest does.
    static func sanitize(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        return clean.isEmpty ? "?" : clean
    }

    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: break
        }
        if first.properties.isEmojiPresentation || scalars.contains("\u{FE0F}") { return 2 }
        return isWide(first.value) ? 2 : 1
    }

    /// East Asian Wide and Fullwidth blocks — the ranges that matter for file
    /// names, not the full UAX #11 table.
    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v)
            || (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v)
    }

    /// At most `width` cells, cut at the end with "…".
    static func fit(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard self.width(text) > width else { return text }
        var out = ""
        var used = 0
        for character in text {
            let w = self.width(of: character)
            if used + w > width - 1 { break }
            out.append(character)
            used += w
        }
        return out + "…"
    }

    /// At most `width` cells, cut at the start with "…" — for paths.
    static func fitLeading(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard self.width(text) > width else { return text }
        var out = ""
        var used = 0
        for character in text.reversed() {
            let w = self.width(of: character)
            if used + w > width - 1 { break }
            out.insert(character, at: out.startIndex)
            used += w
        }
        return "…" + out
    }

    static func padLeft(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - self.width(text))) + text
    }

    static func padRight(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - self.width(text)))
    }

    /// A proportion as a bar of `width` cells, in eighths of a cell.
    static func bar(_ fraction: Double, width: Int) -> String {
        guard width > 0 else { return "" }
        let eighths = Int((min(max(fraction, 0), 1) * Double(width * 8)).rounded())
        let full = eighths / 8
        let partial = eighths % 8
        var s = String(repeating: "█", count: full)
        if partial > 0 { s.append(["▏", "▎", "▍", "▌", "▋", "▊", "▉"][partial - 1]) }
        return padRight(s, width)
    }
}
