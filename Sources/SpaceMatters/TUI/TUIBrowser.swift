import Foundation

/// The directory browser: the window's outline, in a terminal.
///
/// Pure over `FSNode` and scalars, like `TreeDigest`: no file descriptor, no
/// escape sequence written anywhere — `body` returns the frame's lines, so
/// every screen it can draw is a value a test can compare, and the keys it
/// cannot answer itself come back as a [TUIRequest](x-source-tag://TUIRequest)
/// for the app to act on. The terminal plumbing lives in
/// [Terminal](x-source-tag://Terminal), the actions in
/// [AppTUIHost](x-source-tag://AppTUIHost).
struct TUIBrowser {

    /// One line of the listing: a sub-folder, one of the folder's own files, or
    /// the files rolled into a single row — the aggregate the tree keeps while
    /// a listing is still on its way (files are never nodes, see `FSNode`).
    ///
    /// Every number it shows is **sampled once**, when the row is built. The
    /// tree's atomics keep moving under a live scan: a row that re-read them
    /// at draw time could be ranked by one size and printed with another, and
    /// a share computed against a total read a moment later can exceed 100 %.
    struct Row: Equatable {
        enum Kind: Equatable {
            case folder(FSNode)
            case file(TUIFile)
            case ownFiles(count: Int64)
            /// The listing is capped per folder; this is what it did not show.
            case moreFiles(count: Int64)
        }

        let kind: Kind
        let bytes: Int64
        let files: Int64
        /// Unix seconds; 0 means unknown, never 1970.
        let written: Int64
        /// Raw name, for sorting. Sanitised only on the way to the screen.
        let name: String
        var isScanned = true
        /// The folder could not be opened — it is not empty, it is closed.
        var isUnreadable = false

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.kind == rhs.kind && lhs.bytes == rhs.bytes && lhs.files == rhs.files
        }
    }

    /// How rows are ranked. Size first, as everywhere in the app — the others
    /// exist because "what did I touch last" and "what has the most files in
    /// it" are the two questions a size ranking cannot answer.
    enum Sort: CaseIterable {
        case size, name, files, written

        var label: String {
            switch self {
            case .size: return "size"
            case .name: return "name"
            case .files: return "files"
            case .written: return "written"
            }
        }

        var next: Sort {
            let all = Sort.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    /// The selection follows a *node*, not an index: sizes keep moving while
    /// the scan runs, rows re-sort ten times a second, and a highlight pinned to
    /// "row 3" would slide onto another folder under the user's cursor.
    private enum Selection: Equatable {
        case folder(FSNode)
        case file(String)
        case ownFiles
    }

    let root: FSNode
    let rootPath: String
    /// Root first, current folder last. Never empty.
    private(set) var trail: [FSNode]
    private(set) var showTypes = false
    private(set) var sort: Sort = .size
    /// Files in the current folder, listed on demand by the host. Re-asked when
    /// the folder changes or its file count does — during a live scan that is
    /// exactly when a listing becomes stale.
    private var listing: (node: ObjectIdentifier, count: Int64, files: [TUIFile])?
    /// Supplies the current folder's files. Defaults to "none listed", which is
    /// what a VM or SSH scan can offer: their paths are not this machine's.
    var filesProvider: (FSNode) -> [TUIFile] = { _ in [] }

    private var selection: Selection?
    /// The rows of the last frame drawn — what the next key resolves against.
    private var displayed: [Row] = []
    private var scrollTop = 0
    private var typesScroll = 0
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

    /// What an action (delete, reveal, info) applies to right now.
    var target: TUITarget? {
        let rows = visibleRows()
        guard !rows.isEmpty else { return nil }
        switch rows[selectedIndex(in: rows)].kind {
        case .folder(let node): return .folder(node)
        case .file(let file): return .file(file, in: current)
        case .ownFiles, .moreFiles: return nil
        }
    }

    /// The rows the user is actually looking at. A key must act on the frame
    /// on screen, not on a fresh ranking computed between two of them.
    private func visibleRows() -> [Row] {
        displayed.isEmpty ? rows() : displayed
    }

    // MARK: Rows

    /// Sub-folders and files largest first (or by whatever `sort` says), own
    /// files ranked among them — the order the digest uses, so the terminal and
    /// the briefing read the same way.
    func rows() -> [Row] {
        let node = current
        var rows: [Row] = node.children.map { child in
            Row(kind: .folder(child), bytes: child.sizeOnDisk,
                files: child.fileCount.load(ordering: .relaxed),
                written: child.newestMTime.load(ordering: .relaxed),
                name: child.name, isScanned: child.isScanned, isUnreadable: child.isUnreadable)
        }

        let listed = listing?.node == ObjectIdentifier(node) ? (listing?.files ?? []) : []
        let ownWritten = node.directNewestMTime
        for file in listed {
            rows.append(Row(kind: .file(file), bytes: file.bytes, files: 1,
                            written: ownWritten, name: file.name))
        }

        switch sort {
        case .size: rows.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        case .name: rows.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .files: rows.sort { $0.files != $1.files ? $0.files > $1.files : $0.bytes > $1.bytes }
        case .written: rows.sort { $0.written != $1.written ? $0.written > $1.written : $0.bytes > $1.bytes }
        }

        // What the listing did not show stays visible as one aggregate — the
        // bytes have to be somewhere. It has no name and no timestamp of its
        // own, so it is ranked by size among the rows when that is the
        // ordering, and parked at the end when it is not.
        let shown = Int64(listed.count)
        let total = node.directFileCount
        if total > shown {
            let bytes = max(0, node.directFilesPhysical - listed.reduce(0) { $0 + $1.bytes })
            let kind: Row.Kind = listed.isEmpty ? .ownFiles(count: total) : .moreFiles(count: total - shown)
            let row = Row(kind: kind, bytes: bytes, files: total - shown, written: ownWritten, name: "")
            let at = sort == .size ? (rows.firstIndex { $0.bytes < bytes } ?? rows.count) : rows.count
            rows.insert(row, at: at)
        }
        return rows
    }

    /// The folder's own size, as the sum of what is on screen. Taking it from
    /// the node instead would be a *second* sample, and a share drawn against
    /// it could read 103 %.
    private func total(of rows: [Row]) -> Int64 {
        rows.reduce(0) { $0 + $1.bytes }
    }

    private func selectedIndex(in rows: [Row]) -> Int {
        guard let selection else { return 0 }
        return rows.firstIndex { row in
            switch (row.kind, selection) {
            case (.folder(let a), .folder(let b)): return a === b
            case (.file(let a), .file(let name)): return a.name == name
            case (.ownFiles, .ownFiles), (.moreFiles, .ownFiles): return true
            default: return false
            }
        } ?? 0
    }

    private mutating func select(_ row: Row) {
        switch row.kind {
        case .folder(let node): selection = .folder(node)
        case .file(let file): selection = .file(file.name)
        case .ownFiles, .moreFiles: selection = .ownFiles
        }
    }

    /// Pin the selection to the top row before the first frame is drawn.
    /// Without it the highlight is "whatever is first *now*", and it slides
    /// from folder to folder as the scan re-ranks them under the user.
    private mutating func pinSelection(_ rows: [Row]) {
        guard selection == nil, let first = rows.first else { return }
        select(first)
    }

    /// Pull the current folder's file listing. Cheap and idempotent: the host
    /// caches it, and the count tag is what makes it live-scan safe.
    mutating func refreshListing() {
        let node = current
        let key = ObjectIdentifier(node)
        let count = node.directFileCount
        if let listing, listing.node == key, listing.count == count { return }
        listing = (key, count, filesProvider(node))
    }

    // MARK: Keys

    mutating func apply(_ key: TerminalKey) -> TUIRequest {
        if showTypes { return applyInTypes(key) }
        let rows = visibleRows()
        let page = max(1, listHeight - 1)
        switch key {
        case .up, .char("k"): move(by: -1, in: rows)
        case .down, .char("j"): move(by: 1, in: rows)
        case .pageUp: move(by: -page, in: rows)
        case .pageDown: move(by: page, in: rows)
        case .home, .char("g"): move(by: -rows.count, in: rows)
        case .end, .char("G"): move(by: rows.count, in: rows)
        case .enter, .right, .char("l"):
            if !open(in: rows), let target { return .info(target) }
        case .left, .char("h"), .backspace, .escape:
            // esc means "out of here", not "out of the scan": it walks up, and
            // only leaves once there is nowhere left to walk up to.
            if !back() { return .back }
        case .char("q"): return .back
        case .char("t"): showTypes = true; typesScroll = 0
        case .char("s"): sort = sort.next
        case .char("/"): return .find(current)
        case .char("T"): return .top(current)
        case .char("A"): return .aged(current)
        case .char("i"): if let target { return .info(target) }
        case .char("c"): return .copyBriefing
        case .char("o"): if let target { return .reveal(target) }
        case .char("e"): if let target { return .open(target) }
        case .char("r"): return .rescan(current)
        case .char("R"): return .rescanAll
        case .char("d"), .delete: if let target { return .confirmDelete(target, permanently: false) }
        case .char("D"): if let target { return .confirmDelete(target, permanently: true) }
        case .char("m"): return .menu
        case .char("?"): return .help
        default: break
        }
        return .none
    }

    private mutating func applyInTypes(_ key: TerminalKey) -> TUIRequest {
        switch key {
        case .char("t"), .left, .char("h"), .backspace, .escape:
            showTypes = false
        case .char("q"): return .back
        case .up, .char("k"): typesScroll = max(0, typesScroll - 1)
        case .down, .char("j"): typesScroll += 1
        case .pageUp: typesScroll = max(0, typesScroll - max(1, listHeight - 1))
        case .pageDown: typesScroll += max(1, listHeight - 1)
        case .home, .char("g"): typesScroll = 0
        case .char("?"): return .help
        case .char("m"): return .menu
        default: break
        }
        return .none
    }

    private mutating func move(by delta: Int, in rows: [Row]) {
        guard !rows.isEmpty else { return }
        let index = min(max(selectedIndex(in: rows) + delta, 0), rows.count - 1)
        select(rows[index])
    }

    /// Enter the selected folder. `false` when the row is not a folder — the
    /// caller turns that into "show what this file is" rather than a dead key.
    private mutating func open(in rows: [Row]) -> Bool {
        guard !rows.isEmpty, case .folder(let node) = rows[selectedIndex(in: rows)].kind else { return false }
        trail.append(node)
        selection = nil
        scrollTop = 0
        listing = nil
        displayed = []
        return true
    }

    /// Up one level, landing on the folder just left — so ← then → is a no-op.
    /// `false` at the root, where ← means "leave this scan".
    @discardableResult
    private mutating func back() -> Bool {
        guard trail.count > 1 else { return false }
        selection = .folder(trail.removeLast())
        scrollTop = 0
        listing = nil
        displayed = []
        return true
    }

    /// Jump straight to a folder found elsewhere (a search hit), with the
    /// trail rebuilt so ← still walks back out the way the tree goes.
    mutating func walk(to chain: [FSNode]) {
        trail = [root] + chain
        selection = nil
        scrollTop = 0
        listing = nil
        displayed = []
    }

    /// Drop navigation that pointed into a subtree that no longer exists. Called
    /// after a delete: the trail may be standing inside what was removed.
    mutating func reconcile() {
        var trimmed = [trail[0]]
        for node in trail.dropFirst() {
            guard trimmed.last?.children.contains(where: { $0 === node }) == true else { break }
            trimmed.append(node)
        }
        if trimmed.count != trail.count {
            trail = trimmed
            scrollTop = 0
        }
        selection = nil
        listing = nil
        displayed = []
    }

    // MARK: Rendering

    var title: String { showTypes ? "File types" : "Browse" }

    /// The context line: where you are, and what is there.
    func subtitle(width: Int, typeCount: Int) -> String {
        if showTypes { return "whole scan, exact — \(Format.count(Int64(typeCount))) types" }
        let node = current
        var facts = "\(Format.bytes(node.sizeOnDisk)) on disk · "
            + Format.plural(node.fileCount.load(ordering: .relaxed), "file")
        if node.isUnreadable { facts += " · unreadable" }
        if let divergence = node.divergence { facts += " · \(divergence.label)" }
        if sort != .size { facts += " · by \(sort.label)" }
        // Keep the facts and cut the path from the left: its end is the part
        // that says where you are.
        let suffix = "  " + facts
        let room = width - TextCell.width(suffix)
        let path = TextCell.sanitize(currentPath)
        guard room >= 8 else { return TextCell.fit(path + suffix, width) }
        return TextCell.fitLeading(path, room) + suffix
    }

    /// The footer is a *starting* legend, not the key map: it names one way to
    /// do each thing a newcomer needs, and stops. The vi aliases (`j/k/h/l`),
    /// `g`/`G` and the page keys are deliberately absent — they are the
    /// shortcuts of someone who already knows the browser, and spelling them
    /// out here costs the row its last column on an 80-cell terminal, where
    /// the footer is the one line that must stay readable. `?` and `m` carry
    /// the full map, and both are advertised right here.
    var hints: [String] {
        showTypes
            ? ["t/← folders", "↑↓ scroll", "? help"]
            : ["↑↓ move", "→ open", "← up", "d Trash", "t types", "/ find", "m menu", "? help"]
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

    /// Exactly `height` lines, none wider than `width` cells once its SGR
    /// sequences are set aside.
    mutating func body(width: Int, height: Int, types: [ExtRow]) -> [String] {
        let width = max(width, 1)
        listHeight = max(0, height - 1)
        return showTypes ? typesBody(types, width: width) : listBody(width: width)
    }

    private mutating func listBody(width: Int) -> [String] {
        let columns = Columns(width: width)
        displayed = rows()
        pinSelection(displayed)
        var out = [Style.dim(TextCell.fit(line(size: "on disk", percent: "%", bar: "", files: "files",
                                               age: "written", name: "name", columns: columns), width))]
        guard listHeight > 0 else { return out }

        let rows = displayed
        let selected = rows.isEmpty ? 0 : selectedIndex(in: rows)
        if selected < scrollTop { scrollTop = selected }
        if selected >= scrollTop + listHeight { scrollTop = selected - listHeight + 1 }
        scrollTop = max(0, min(scrollTop, max(0, rows.count - listHeight)))

        let total = self.total(of: rows)
        for index in rows.indices.dropFirst(scrollTop).prefix(listHeight) {
            let text = TextCell.fit(describe(rows[index], total: total, columns: columns), width)
            if index == selected {
                out.append(Style.reverse(TextCell.padRight(text, width)))
            } else if case .folder = rows[index].kind {
                out.append(rows[index].isUnreadable ? Style.yellow(text) : text)
            } else {
                out.append(Style.dim(text)) // files read as leaves, folders as the way down
            }
        }
        if rows.isEmpty {
            out.append(Style.dim(TextCell.fit("  " + emptyReason, width)))
        }
        return padded(out, to: listHeight + 1)
    }

    /// Why there is nothing to list. "No files" and "I was not allowed to
    /// look" are the same empty screen and opposite facts: a folder reported
    /// as empty because it was refused is how a user concludes there is
    /// nothing to reclaim in the one place there is.
    private var emptyReason: String {
        if current.isUnreadable {
            return "(unreadable — permission denied. Full Disk Access in System Settings "
                + "› Privacy & Security would let it be read)"
        }
        return current.isScanned ? "(no files)" : "(scanning…)"
    }

    private func describe(_ row: Row, total: Int64, columns: Columns) -> String {
        let name: String
        switch row.kind {
        case .folder(let node):
            // A trailing "…" marks a folder no worker has read yet: its row is
            // a placeholder that will fill in, not a small folder.
            name = TextCell.sanitize(node.name) + "/"
                + (row.isUnreadable ? "  (unreadable)" : (row.isScanned ? "" : " …"))
        case .file(let file):
            name = TextCell.sanitize(file.name) + (file.divergence != nil ? "  (sparse)" : "")
        case .ownFiles(let count):
            name = "[\(Format.plural(count, "file")) here]"
        case .moreFiles(let count):
            name = "[\(Format.plural(count, "more file"))]"
        }
        let fraction = total > 0 ? Double(row.bytes) / Double(total) : 0
        // 0 means unknown (streamed scans carry no timestamps) — never 1970.
        let age = row.written > 0 ? Format.age(Date(timeIntervalSince1970: Double(row.written))) : "—"
        return line(size: Format.bytes(row.bytes), percent: String(format: "%.1f%%", fraction * 100),
                    bar: TextCell.bar(fraction, width: columns.bar), files: Format.count(row.files),
                    age: age, name: name, columns: columns)
    }

    private mutating func typesBody(_ types: [ExtRow], width: Int) -> [String] {
        let showBar = width >= 50
        var out = [Style.dim(TextCell.fit(
            TextCell.padLeft("on disk", 10) + "  " + TextCell.padLeft("%", 6)
            + (showBar ? "  " + TextCell.padRight("", 10) : "")
            + "  " + TextCell.padLeft("files", 11) + "  type", width))]
        typesScroll = max(0, min(typesScroll, max(0, types.count - listHeight)))
        let total = root.sizeOnDisk
        for row in types.dropFirst(typesScroll).prefix(listHeight) {
            let fraction = total > 0 ? Double(row.physical) / Double(total) : 0
            var s = TextCell.padLeft(Format.bytes(row.physical), 10)
                + "  " + TextCell.padLeft(String(format: "%.1f%%", fraction * 100), 6)
            if showBar { s += "  " + TextCell.bar(fraction, width: 10) }
            s += "  " + TextCell.padLeft(Format.count(row.count), 11) + "  " + TextCell.sanitize(row.name)
            out.append(TextCell.fit(s, width))
        }
        return padded(out, to: listHeight + 1)
    }

    private func padded(_ lines: [String], to count: Int) -> [String] {
        lines.count >= count ? Array(lines.prefix(count)) : lines + Array(repeating: "", count: count - lines.count)
    }
}
