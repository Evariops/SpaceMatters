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
    enum Row: Equatable {
        case folder(FSNode)
        case file(TUIFile)
        case ownFiles(count: Int64, bytes: Int64)
        /// The listing is capped per folder; this is what it did not show.
        case moreFiles(count: Int64, bytes: Int64)
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
        let rows = self.rows()
        guard !rows.isEmpty else { return nil }
        switch rows[selectedIndex(in: rows)] {
        case .folder(let node): return .folder(node)
        case .file(let file): return .file(file, in: current)
        case .ownFiles, .moreFiles: return nil
        }
    }

    // MARK: Rows

    /// Sub-folders and files largest first (or by whatever `sort` says), own
    /// files ranked among them — the order the digest uses, so the terminal and
    /// the briefing read the same way.
    func rows() -> [Row] {
        let node = current
        // Sizes are sampled once: the atomics keep moving under a live scan, and
        // a comparator that reads them twice can disagree with itself.
        var ranked: [(row: Row, bytes: Int64, name: String, files: Int64, written: Int64)] =
            node.children.map {
                (.folder($0), $0.sizeOnDisk, $0.name, $0.fileCount.load(ordering: .relaxed),
                 $0.newestMTime.load(ordering: .relaxed))
            }

        let listed = listing?.node == ObjectIdentifier(node) ? (listing?.files ?? []) : []
        for file in listed {
            ranked.append((.file(file), file.bytes, file.name, 1, node.directNewestMTime))
        }

        switch sort {
        case .size: ranked.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        case .name: ranked.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .files: ranked.sort { $0.files != $1.files ? $0.files > $1.files : $0.bytes > $1.bytes }
        case .written: ranked.sort { $0.written != $1.written ? $0.written > $1.written : $0.bytes > $1.bytes }
        }
        var rows = ranked.map(\.row)

        // What the listing did not show stays visible as one aggregate — the
        // bytes have to be somewhere. It has no name and no timestamp of its
        // own, so it is ranked by size among the rows when that is the
        // ordering, and parked at the end when it is not.
        let shown = Int64(listed.count)
        let total = node.directFileCount
        if total > shown {
            let bytes = max(0, node.directFilesPhysical - listed.reduce(0) { $0 + $1.bytes })
            let row: Row = listed.isEmpty
                ? .ownFiles(count: total, bytes: bytes)
                : .moreFiles(count: total - shown, bytes: bytes)
            let at = sort == .size ? (ranked.firstIndex { $0.bytes < bytes } ?? rows.count) : rows.count
            rows.insert(row, at: at)
        }
        return rows
    }

    private func selectedIndex(in rows: [Row]) -> Int {
        guard let selection else { return 0 }
        return rows.firstIndex { row in
            switch (row, selection) {
            case (.folder(let a), .folder(let b)): return a === b
            case (.file(let a), .file(let name)): return a.name == name
            case (.ownFiles, .ownFiles), (.moreFiles, .ownFiles): return true
            default: return false
            }
        } ?? 0
    }

    private mutating func select(_ row: Row) {
        switch row {
        case .folder(let node): selection = .folder(node)
        case .file(let file): selection = .file(file.name)
        case .ownFiles, .moreFiles: selection = .ownFiles
        }
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
        let rows = self.rows()
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
        guard !rows.isEmpty, case .folder(let node) = rows[selectedIndex(in: rows)] else { return false }
        trail.append(node)
        selection = nil
        scrollTop = 0
        listing = nil
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
        return true
    }

    /// Jump straight to a folder found elsewhere (a search hit), with the
    /// trail rebuilt so ← still walks back out the way the tree goes.
    mutating func walk(to chain: [FSNode]) {
        trail = [root] + chain
        selection = nil
        scrollTop = 0
        listing = nil
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
    }

    // MARK: Rendering

    var title: String { showTypes ? "File types" : "Browse" }

    /// The context line: where you are, and what is there.
    func subtitle(width: Int, typeCount: Int) -> String {
        if showTypes { return "whole scan, exact — \(Format.count(Int64(typeCount))) types" }
        let node = current
        var facts = "\(Format.bytes(node.sizeOnDisk)) on disk · \(Format.count(node.fileCount.load(ordering: .relaxed))) files"
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
        var out = [Style.dim(TextCell.fit(line(size: "on disk", percent: "%", bar: "", files: "files",
                                               age: "written", name: "name", columns: columns), width))]
        guard listHeight > 0 else { return out }

        let rows = self.rows()
        let selected = rows.isEmpty ? 0 : selectedIndex(in: rows)
        if selected < scrollTop { scrollTop = selected }
        if selected >= scrollTop + listHeight { scrollTop = selected - listHeight + 1 }
        scrollTop = max(0, min(scrollTop, max(0, rows.count - listHeight)))

        let total = current.sizeOnDisk
        for index in rows.indices.dropFirst(scrollTop).prefix(listHeight) {
            let text = TextCell.fit(describe(rows[index], total: total, columns: columns), width)
            if index == selected {
                out.append(Style.reverse(TextCell.padRight(text, width)))
            } else if case .folder = rows[index] {
                out.append(text)
            } else {
                out.append(Style.dim(text)) // files read as leaves, folders as the way down
            }
        }
        if rows.isEmpty {
            out.append(Style.dim(TextCell.fit(current.isScanned ? "  (no files)" : "  (scanning…)", width)))
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
        case .file(let file):
            bytes = file.bytes
            files = 1
            written = current.directNewestMTime
            name = TextCell.sanitize(file.name) + (file.divergence != nil ? "  (sparse)" : "")
        case .ownFiles(let count, let size):
            bytes = size
            files = count
            written = current.directNewestMTime
            name = "[\(Format.count(count)) files here]"
        case .moreFiles(let count, let size):
            bytes = size
            files = count
            written = current.directNewestMTime
            name = "[\(Format.count(count)) more files]"
        }
        let fraction = total > 0 ? Double(bytes) / Double(total) : 0
        // 0 means unknown (streamed scans carry no timestamps) — never 1970.
        let age = written > 0 ? Format.age(Date(timeIntervalSince1970: Double(written))) : "—"
        return line(size: Format.bytes(bytes), percent: String(format: "%.1f%%", fraction * 100),
                    bar: TextCell.bar(fraction, width: columns.bar), files: Format.count(files),
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
