import Foundation

/// The terminal UI, as one state machine over a [TUIHost](x-source-tag://TUIHost).
///
/// It owns the routing (home → browser → results, cleanup, read-only tables),
/// the chrome every screen shares (header, context line, footer) and the
/// overlays that make destructive work safe to do with a keystroke:
/// confirmations, the action menu, the help card.
///
/// Nothing here touches a file descriptor or a disk: keys go in, lines come
/// out, and everything that *acts* goes through the host. That is what lets
/// the whole interface — including "yes, delete it" — be tested as values.
///
/// - Tag: TUIApp
final class TUIApp {

    enum Route { case home, browser, results, cleanup, table }

    /// A modal drawn over the current screen. Keys go to it alone while it is
    /// up: a confirmation you can navigate behind is not a confirmation.
    enum Overlay {
        case help
        case menu(Menu)
        case confirm(Confirm)
        case prompt(Prompt)
        case note(title: String, lines: [String])
    }

    struct Menu {
        let title: String
        var items: [Item]
        var selected = 0

        struct Item {
            /// The key that also runs it from the screen below, shown as a hint.
            let key: String
            let label: String
            let request: TUIRequest
        }
    }

    struct Confirm {
        let title: String
        let lines: [String]
        let danger: Bool
        /// Typed confirmation: `⏎` is enough for the reversible path (the
        /// Trash), `y` is required where nothing comes back.
        let requiresYes: Bool
        let action: () -> Void
    }

    struct Prompt {
        let title: String
        let hint: String
        var value: String
        let submit: (String) -> Void
    }

    private let host: TUIHost
    private(set) var route: Route = .home
    private(set) var overlay: Overlay?

    private var home = TUIHome()
    private var browser: TUIBrowser?
    private var results: TUIResults?
    private var cleanupScreen = TUICleanupScreen()
    private var tableScreen: TUITableScreen?

    private var status = TUIStatus()
    /// The last thing that happened, shown in the footer until the next key.
    private var note: String?
    private var tick = 0

    init(host: TUIHost) {
        self.host = host
        host.reloadSources()
    }

    /// `--tui <path>`: skip the menu and start browsing that folder.
    func open(path: String) {
        start(.path(path))
    }

    // MARK: Frame

    /// Pull whatever the host has for us. Called once per frame, before
    /// `render` — the screens stay values, this is where they are refreshed.
    func refresh() {
        tick += 1
        status = host.status
        if let note = host.takeNote() {
            self.note = note
            // A job that just landed may have detached nodes the screens are
            // still pointing at.
            browser?.reconcile()
            if results != nil {
                results?.keep(host.root.map(Self.liveNodes) ?? [])
            }
        }
        switch route {
        case .home:
            home.sources = host.sources
        case .browser:
            if let root = host.root {
                if browser == nil || browser?.root !== root { makeBrowser(root: root) }
                browser?.refreshListing()
            } else if status.phase == .idle {
                browser = nil
                route = .home
            }
            if status.phase == .failed, let failure = status.failure, overlay == nil {
                overlay = .note(title: "That scan could not run", lines: TextCell.wrap(failure, 56))
            }
        case .cleanup:
            cleanupScreen.state = host.cleanup
        case .table:
            if let kind = tableScreen?.kind { tableScreen?.table = host.table(kind) }
        case .results:
            break
        }
    }

    private func makeBrowser(root: FSNode) {
        var browser = TUIBrowser(root: root, rootPath: status.rootPath)
        browser.filesProvider = { [host] node in host.files(in: node) }
        browser.refreshListing()
        self.browser = browser
    }

    // MARK: Keys

    /// Applies one key. `false` when the app should close.
    func apply(_ key: TerminalKey) -> Bool {
        note = nil
        if key == .interrupt { return confirmQuitIfBusy() }
        if overlay != nil { return applyInOverlay(key) }

        let request: TUIRequest
        switch route {
        case .home: request = home.apply(key)
        case .browser: request = browser?.apply(key) ?? .back
        case .results: request = results?.apply(key) ?? .back
        case .cleanup: request = cleanupScreen.apply(key)
        case .table: request = tableScreen?.apply(key) ?? .back
        }
        return handle(request)
    }

    private func applyInOverlay(_ key: TerminalKey) -> Bool {
        switch overlay {
        case .help, .note:
            overlay = nil
        case .menu(var menu):
            switch key {
            case .up, .char("k"): menu.selected = max(0, menu.selected - 1)
            case .down, .char("j"): menu.selected = min(menu.items.count - 1, menu.selected + 1)
            case .enter, .right, .char("l"):
                overlay = nil
                return handle(menu.items[menu.selected].request)
            case .escape, .char("q"), .char("m"), .left: overlay = nil
            case .char(let c):
                // The menu is also a key legend: typing the shortcut runs it.
                if let item = menu.items.first(where: { $0.key == String(c) }) {
                    overlay = nil
                    return handle(item.request)
                }
            default: break
            }
            if case .menu = overlay { overlay = .menu(menu) }
        case .confirm(let confirm):
            switch key {
            case .char("y"), .char("Y"):
                overlay = nil
                confirm.action()
            case .enter where !confirm.requiresYes:
                overlay = nil
                confirm.action()
            case .escape, .char("n"), .char("N"), .char("q"):
                overlay = nil
                note = "Cancelled — nothing was touched"
            default: break
            }
        case .prompt(var prompt):
            switch key {
            case .enter:
                overlay = nil
                let value = prompt.value.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { prompt.submit(value) }
            case .escape: overlay = nil
            case .backspace:
                if !prompt.value.isEmpty { prompt.value.removeLast() }
                overlay = .prompt(prompt)
            case .char(let c):
                prompt.value.append(c)
                overlay = .prompt(prompt)
            default: break
            }
        case nil:
            break
        }
        return true
    }

    // MARK: Requests

    private func handle(_ request: TUIRequest) -> Bool {
        switch request {
        case .none:
            break

        case .quit:
            return confirmQuitIfBusy()

        case .back:
            switch route {
            case .home: return confirmQuitIfBusy()
            case .browser:
                host.goHome()
                browser = nil
                route = .home
            case .results:
                results = nil
                route = .browser
            case .cleanup, .table:
                route = .home
            }

        case .help:
            overlay = .help

        case .menu:
            overlay = .menu(menu(for: route))

        case .info(let target):
            overlay = .note(title: target.name, lines: describe(target))

        case .confirmDelete(let target, let permanently):
            confirmDelete(target, permanently: permanently)

        case .rescan(let node):
            guard status.canDelete else { return noteRefusal() }
            host.rescan(node)

        case .rescanAll:
            host.rescanAll()
            browser = nil
            note = "Rescanning…"

        case .cancelScan:
            host.cancelScan()

        case .copyBriefing:
            host.copyBriefing()

        case .reveal(let target):
            guard status.isHostScan else { return noteRefusal() }
            if let path = path(of: target) { host.reveal(path) }

        case .open(let target):
            guard status.isHostScan else { return noteRefusal() }
            if let path = path(of: target) { host.open(path) }

        case .goTo(let node):
            goTo(node)

        case .find(let node):
            overlay = .prompt(Prompt(
                title: "Find folders by name",
                hint: "glob — node_modules, *.xcarchive, .venv",
                value: "",
                submit: { [weak self] pattern in self?.runFind(pattern, in: node) }))

        case .top(let node):
            show(results: TreeQuery.top(of: node, limit: 200), kind: .top, in: node)

        case .aged(let node):
            let days = 180.0
            show(results: TreeQuery.aged(in: node, olderThanDays: days, minBytes: 10 << 20),
                 kind: .aged(days: days), in: node)

        case .start(let source):
            start(source)

        case .promptPath:
            overlay = .prompt(Prompt(
                title: "Scan a path",
                hint: "absolute path, or ~ for your home folder",
                value: "",
                submit: { [weak self] path in self?.startPath(path) }))

        case .reloadSources:
            host.reloadSources()

        case .toggle(let id):
            host.toggleCleanup(id)

        case .toggleAll:
            host.toggleAllCleanup()

        case .confirmClean:
            confirmClean()

        case .reloadCleanup:
            host.loadCleanup()

        case .reloadTable:
            if let kind = tableScreen?.kind { host.loadTable(kind) }
        }
        return true
    }

    /// Route to a source and ask the host to begin. Internal rather than
    /// private so a test can land on a screen without replaying the menu.
    func start(_ source: TUISource) {
        switch source {
        case .cleanup:
            route = .cleanup
            cleanupScreen = TUICleanupScreen()
            host.loadCleanup()
        case .kubernetes(let context):
            tableScreen = TUITableScreen(kind: .kubernetes(context: context))
            route = .table
            host.start(source)
        case .containers(let id):
            tableScreen = TUITableScreen(kind: .containers(engineID: id))
            route = .table
            host.start(source)
        case .volume, .path, .vm:
            browser = nil
            results = nil
            route = .browser
            host.start(source)
        }
    }

    private func startPath(_ raw: String) {
        var path = raw
        if path == "~" { path = NSHomeDirectory() }
        if path.hasPrefix("~/") { path = NSHomeDirectory() + String(path.dropFirst(1)) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            note = "No folder at \(path)"
            return
        }
        start(.path(path))
    }

    private func runFind(_ pattern: String, in node: FSNode) {
        // A bare word means "a folder called that", which is what people type.
        let glob = pattern.contains("*") || pattern.contains("?") ? pattern : "*\(pattern)*"
        show(results: TreeQuery.find(in: node, pattern: glob), kind: .find(pattern: glob), in: node)
    }

    private func show(results nodes: [FSNode], kind: TUIResults.Kind, in scope: FSNode) {
        let hits = nodes.map { TUIResults.Hit(node: $0, path: host.path(of: $0) ?? $0.name) }
        results = TUIResults(kind: kind, scope: host.path(of: scope) ?? status.rootPath,
                             hits: hits, scanTotal: host.root?.sizeOnDisk ?? status.onDisk)
        route = .results
    }

    /// Walk the browser to a folder found elsewhere (a search hit).
    ///
    /// The trail is built top-down. Climbing `node.parent` instead would be
    /// shorter and would trap: `parent` is `unowned`, and the hit may be all
    /// that is left of a subtree a delete detached meanwhile.
    private func goTo(_ node: FSNode) {
        guard let root = host.root, let chain = Self.chain(from: root, to: node) else {
            note = "That folder is no longer in the scan"
            return
        }
        if browser == nil || browser?.root !== root { makeBrowser(root: root) }
        browser?.walk(to: chain)
        browser?.refreshListing()
        results = nil
        route = .browser
    }

    /// Root → node, excluding the root. `nil` when the node is not in the tree.
    private static func chain(from root: FSNode, to node: FSNode) -> [FSNode]? {
        if node === root { return [] }
        for child in root.children {
            if let tail = chain(from: child, to: node) { return [child] + tail }
        }
        return nil
    }

    /// Every node still hanging under the root, for screens holding nodes the
    /// tree may have dropped.
    private static func liveNodes(_ root: FSNode) -> Set<ObjectIdentifier> {
        var live: Set<ObjectIdentifier> = []
        var stack = [root]
        while let node = stack.popLast() {
            live.insert(ObjectIdentifier(node))
            stack.append(contentsOf: node.children)
        }
        return live
    }

    // MARK: Destructive paths

    private func confirmDelete(_ target: TUITarget, permanently: Bool) {
        guard status.isHostScan else {
            note = "This scan is read-only — its paths are not this machine's"
            return
        }
        guard !status.isScanning else {
            note = "Wait for the scan to finish — the tree is still being written"
            return
        }
        guard status.busy == nil else {
            note = "Something is already running"
            return
        }
        if case .folder(let node) = target, node.parent == nil {
            note = "That is the root of the scan — pick something inside it"
            return
        }
        guard let path = path(of: target) else {
            note = "Could not resolve that path"
            return
        }

        var lines = [
            "\(Format.bytes(target.bytes)) on disk",
            TextCell.fitLeading(path, 56),
            "",
        ]
        if permanently {
            lines.append("Deleted for good. There is no Trash to fish it out of,")
            lines.append("and no undo.")
            lines.append("")
            lines.append("Press y to delete, esc to cancel.")
        } else {
            lines.append("It goes to the Trash — put it back from Finder if you")
            lines.append("picked the wrong one.")
            lines.append("")
            lines.append("Press ⏎ to move it, esc to cancel.")
        }
        overlay = .confirm(Confirm(
            title: permanently ? "Delete \(target.name) permanently?" : "Move \(target.name) to the Trash?",
            lines: lines,
            danger: permanently,
            requiresYes: permanently,
            action: { [host] in host.delete(target, permanently: permanently) }))
    }

    private func confirmClean() {
        let state = host.cleanup
        let picked = state.selected
        guard state.phase == .ready else {
            note = state.phase == .cleaning ? "Already emptying" : "Still measuring — the sizes have to be real first"
            return
        }
        guard !picked.isEmpty else {
            note = "Nothing picked — space ticks a row, a selects the regenerable ones"
            return
        }
        var lines = ["\(Format.bytes(state.totalSelected)) across \(picked.count) target\(picked.count == 1 ? "" : "s"):", ""]
        for row in picked.prefix(6) {
            lines.append("  · \(row.name) — \(Format.bytes(row.bytes))")
        }
        if picked.count > 6 { lines.append("  · and \(picked.count - 6) more") }
        lines.append("")
        if picked.contains(where: { !$0.regenerable }) {
            lines.append("One of these is NOT regenerable — its bytes do not come back.")
        }
        lines.append("Press y to empty them, esc to cancel.")
        overlay = .confirm(Confirm(
            title: "Empty \(picked.count) target\(picked.count == 1 ? "" : "s")?",
            lines: lines,
            danger: true,
            requiresYes: true,
            action: { [host] in host.cleanSelected() }))
    }

    /// Quitting mid-job would stop a deletion halfway; say so and ask.
    private func confirmQuitIfBusy() -> Bool {
        guard let busy = status.busy else { return false }
        overlay = .confirm(Confirm(
            title: "Quit while this is running?",
            lines: [busy, "", "Quitting now stops it where it stands.",
                    "Press y to quit anyway, esc to stay."],
            danger: true,
            requiresYes: true,
            action: { [weak self] in self?.wantsToQuit = true }))
        return true
    }

    /// Set by the quit confirmation; the frame loop checks it.
    private(set) var wantsToQuit = false

    private func noteRefusal() -> Bool {
        note = status.isHostScan ? "Not while the scan is running" : "This scan is read-only"
        return true
    }

    private func path(of target: TUITarget) -> String? {
        switch target {
        case .folder(let node): return host.path(of: node)
        case .file(let file, let parent):
            guard let base = host.path(of: parent) else { return nil }
            return (base == "/" ? "/" : base + "/") + file.name
        }
    }

    private func describe(_ target: TUITarget) -> [String] {
        var lines: [String] = []
        switch target {
        case .folder(let node):
            lines.append("\(Format.bytes(node.sizeOnDisk)) on disk")
            lines.append("\(Format.count(node.fileCount.load(ordering: .relaxed))) files · \(Format.count(Int64(node.childCount))) sub-folders")
            if let written = node.newestWrite {
                lines.append("newest write \(Format.age(written))")
            } else {
                lines.append("newest write unknown (streamed scan)")
            }
            if let divergence = node.divergence {
                lines += TextCell.wrap(divergence.summary, 56)
            }
            if !node.isScanned { lines.append("still being read by the scanner") }
        case .file(let file, _):
            lines.append("\(Format.bytes(file.bytes)) on disk")
            if file.apparent != file.bytes {
                lines.append("\(Format.bytes(file.apparent)) apparent")
            }
            if let divergence = file.divergence { lines += TextCell.wrap(divergence.summary, 56) }
        }
        if let path = path(of: target) {
            lines.append("")
            lines += TextCell.wrap(path, 56)
        }
        return lines
    }

    // MARK: Menu & help

    private func menu(for route: Route) -> Menu {
        switch route {
        case .home:
            return Menu(title: "SpaceMatters", items: [
                .init(key: "⏎", label: "Analyse what is selected", request: .none),
                .init(key: "/", label: "Scan a path…", request: .promptPath),
                .init(key: "", label: "Low-Hanging Fruits — safe cleanup", request: .start(.cleanup)),
                .init(key: "r", label: "Look for disks and machines again", request: .reloadSources),
                .init(key: "?", label: "Keys", request: .help),
                .init(key: "q", label: "Quit", request: .quit),
            ])
        case .browser:
            guard let current = browser?.current else {
                return Menu(title: "Browse", items: [.init(key: "q", label: "Back to the home menu", request: .back)])
            }
            let target = browser?.target
            var items: [Menu.Item] = [
                .init(key: "t", label: "File types across the whole scan", request: .none),
                .init(key: "/", label: "Find folders by name…", request: .find(current)),
                .init(key: "T", label: "Largest folders in here", request: .top(current)),
                .init(key: "A", label: "Cold folders — untouched for 6 months", request: .aged(current)),
                .init(key: "c", label: "Copy a briefing for an assistant", request: .copyBriefing),
            ]
            if let target {
                items.insert(.init(key: "i", label: "What is \(target.name)?", request: .info(target)), at: 0)
                items.append(.init(key: "o", label: "Reveal in Finder", request: .reveal(target)))
                items.append(.init(key: "d", label: "Move \(target.name) to the Trash",
                                   request: .confirmDelete(target, permanently: false)))
                items.append(.init(key: "D", label: "Delete \(target.name) permanently",
                                   request: .confirmDelete(target, permanently: true)))
            }
            items.append(.init(key: "r", label: "Re-read this folder from disk", request: .rescan(current)))
            items.append(.init(key: "R", label: "Rescan everything", request: .rescanAll))
            if status.isScanning { items.append(.init(key: "", label: "Stop the scan", request: .cancelScan)) }
            items.append(.init(key: "q", label: "Back to the home menu", request: .back))
            return Menu(title: current.name, items: items)
        case .results:
            var items: [Menu.Item] = []
            if let target = results?.target, let node = target.folderNode {
                items.append(.init(key: "⏎", label: "Go to \(target.name)", request: .goTo(node)))
                items.append(.init(key: "i", label: "What is \(target.name)?", request: .info(target)))
                items.append(.init(key: "d", label: "Move \(target.name) to the Trash",
                                   request: .confirmDelete(target, permanently: false)))
            }
            items.append(.init(key: "esc", label: "Back to the browser", request: .back))
            return Menu(title: results?.title ?? "Results", items: items)
        case .cleanup:
            return Menu(title: "Low-Hanging Fruits", items: [
                .init(key: "space", label: "Pick the row under the cursor", request: .none),
                .init(key: "a", label: "Pick every regenerable target", request: .toggleAll),
                .init(key: "⏎", label: "Empty what is picked", request: .confirmClean),
                .init(key: "r", label: "Measure again", request: .reloadCleanup),
                .init(key: "esc", label: "Back to the home menu", request: .back),
            ])
        case .table:
            return Menu(title: tableScreen?.title ?? "Table", items: [
                .init(key: "r", label: "Query again", request: .reloadTable),
                .init(key: "esc", label: "Back to the home menu", request: .back),
            ])
        }
    }

    private var helpLines: [String] {
        var lines = [
            "MOVE      ↑↓ / j k · PgUp PgDn · g G (top, bottom)",
            "OPEN      → or ⏎ · ← or ⌫ goes back up",
            "",
        ]
        switch route {
        case .browser:
            lines += [
                "LOOK      t file types · i what is this · s change sort",
                "FIND      / by name · T largest · A cold (6 months+)",
                "DELETE    d to the Trash · D permanently (asks first)",
                "REFRESH   r re-read this folder · R rescan everything",
                "SHARE     c copy a briefing for an assistant",
                "FINDER    o reveal · e open",
            ]
        case .results:
            lines += [
                "⏎         go to that folder in the browser",
                "d / D     Trash it · delete it permanently",
                "i         size, age and full path",
            ]
        case .cleanup:
            lines += [
                "space     tick the target under the cursor",
                "a         tick every regenerable target",
                "⏎ or c    empty what is ticked (asks first)",
                "r         measure everything again",
            ]
        case .home:
            lines += [
                "⏎         analyse the selected disk, VM or context",
                "/         type a path to scan",
                "r         look for disks and machines again",
            ]
        case .table:
            lines += ["r         run the query again"]
        }
        lines += ["", "m         the action menu · q back · Ctrl-C quit"]
        return lines
    }

    // MARK: Rendering

    func render(width: Int, height: Int) -> [String] {
        let width = max(width, 1)
        let height = max(height, 1)
        var lines = [header(width: width), contextLine(width: width)]
        let bodyHeight = max(0, height - 3)
        // A screen that returns more (or fewer) lines than it was given must
        // not push the footer off the terminal.
        var rendered = body(width: width, height: bodyHeight)
        rendered = Array(rendered.prefix(bodyHeight))
        lines += rendered + Array(repeating: "", count: bodyHeight - rendered.count)
        lines.append(footer(width: width))
        lines = Array(lines.prefix(height))
        if let overlay { lines = draw(overlay, over: lines, width: width) }
        while lines.count < height { lines.append("") }
        return lines
    }

    private func body(width: Int, height: Int) -> [String] {
        switch route {
        case .home: return home.body(width: width, height: height)
        case .browser:
            guard browser != nil else {
                return [Style.dim(TextCell.fit("  starting the scan…", width))]
                    + Array(repeating: "", count: max(0, height - 1))
            }
            return browser!.body(width: width, height: height, types: status.types)
        case .results:
            guard results != nil else { return Array(repeating: "", count: height) }
            return results!.body(width: width, height: height)
        case .cleanup: return cleanupScreen.body(width: width, height: height)
        case .table:
            guard tableScreen != nil else { return Array(repeating: "", count: height) }
            return tableScreen!.body(width: width, height: height)
        }
    }

    private func header(width: Int) -> String {
        let title = "SpaceMatters"
        var facts: String
        if let busy = status.busy {
            facts = "\(Style.spinner(tick)) \(busy)"
        } else {
            switch route {
            case .home:
                facts = "disks, machines and clusters on this Mac"
            case .cleanup, .table:
                facts = screenTitle
            case .browser, .results:
                facts = status.isScanning
                    ? String(format: "scanning… %.1f s", status.elapsed)
                    : String(format: "scanned in %.1f s", status.elapsed)
                facts += " · \(Format.count(status.files)) files · \(Format.count(status.folders)) folders"
                if status.skipped > 0 { facts += " · \(Format.count(status.skipped)) unreadable, skipped" }
            }
        }
        guard width > TextCell.width(title) else { return Style.bold(TextCell.fit(title, width)) }
        return Style.bold(title) + TextCell.fit("  " + facts, width - TextCell.width(title))
    }

    private var screenTitle: String {
        switch route {
        case .home: return home.title
        case .browser: return browser?.title ?? "Browse"
        case .results: return results?.title ?? "Results"
        case .cleanup: return cleanupScreen.title
        case .table: return tableScreen?.title ?? ""
        }
    }

    private func contextLine(width: Int) -> String {
        switch route {
        case .home: return Style.dim(TextCell.fit(home.subtitle(width: width), width))
        case .browser:
            return browser.map { TextCell.fit($0.subtitle(width: width, typeCount: status.types.count), width) } ?? ""

        case .results: return results.map { TextCell.fit($0.subtitle(width: width), width) } ?? ""
        case .cleanup: return TextCell.fit(cleanupScreen.subtitle(width: width), width)
        case .table: return Style.dim(tableScreen.map { TextCell.fit($0.subtitle(width: width), width) } ?? "")
        }
    }

    private func footer(width: Int) -> String {
        if let note {
            return Style.yellow(TextCell.fit("▸ " + note, width))
        }
        let hints: [String]
        switch route {
        case .home: hints = home.hints
        case .browser: hints = browser?.hints ?? []
        case .results: hints = results?.hints ?? []
        case .cleanup: hints = cleanupScreen.hints
        case .table: hints = tableScreen?.hints ?? []
        }
        return Style.dim(TextCell.fit(hints.joined(separator: "   "), width))
    }

    // MARK: Overlays

    private func draw(_ overlay: Overlay, over lines: [String], width: Int) -> [String] {
        let box: [String]
        switch overlay {
        case .help:
            box = boxed(title: "Keys", lines: helpLines, width: width, accent: Style.cyan)
        case .note(let title, let noteLines):
            box = boxed(title: title, lines: noteLines, width: width, accent: Style.cyan)
        case .menu(let menu):
            // Fitted here, before the selection style goes on: a styled string
            // cannot be cut afterwards without cutting an escape sequence.
            let room = max(8, width - 8)
            var items: [String] = []
            for (index, item) in menu.items.enumerated() {
                let key = item.key.isEmpty ? "   " : TextCell.padRight(item.key, 3)
                let text = TextCell.fit(" \(key) \(TextCell.sanitize(item.label))", room)
                items.append(index == menu.selected ? Style.reverse(text) : text)
            }
            box = boxed(title: menu.title, lines: items, width: width, accent: Style.cyan, preStyled: true)
        case .confirm(let confirm):
            box = boxed(title: confirm.title, lines: confirm.lines, width: width,
                        accent: confirm.danger ? Style.boldRed : Style.yellow)
        case .prompt(let prompt):
            box = boxed(title: prompt.title,
                        lines: ["", "› " + prompt.value + "█", "", prompt.hint, "", "⏎ go · esc cancel"],
                        width: width, accent: Style.cyan)
        }
        guard !box.isEmpty, lines.count > box.count else { return lines }
        var out = lines
        let top = max(1, (lines.count - box.count) / 2)
        for (index, line) in box.enumerated() where top + index < out.count {
            out[top + index] = line
        }
        return out
    }

    /// A centred box. Its lines replace whole lines of the screen underneath —
    /// overlaying *part* of a line would mean reasoning about the SGR state
    /// already on it.
    private func boxed(title: String, lines: [String], width: Int,
                       accent: (String) -> String, preStyled: Bool = false) -> [String] {
        // Under ~24 cells a frame costs more room than it gives: the message
        // is what matters, and a border drawn wider than the terminal is the
        // one thing that would corrupt the screen.
        let title = clean(title)
        let lines = preStyled ? lines : lines.map(clean)
        guard width >= 24 else {
            return [Style.bold(TextCell.fit(title, width))]
                + lines.map { TextCell.fit(plain($0), width) }
        }
        let inner = min(max(TextCell.width(title) + 2,
                            lines.map { TextCell.width(plain($0)) }.max() ?? 0), max(8, width - 6))
        let left = String(repeating: " ", count: max(0, (width - inner - 4) / 2))
        var out = [left + accent("┌─ " + TextCell.fit(title, inner - 1) + " "
                                 + String(repeating: "─", count: max(0, inner - TextCell.width(TextCell.fit(title, inner - 1)) - 1)) + "┐")]
        for line in lines {
            let text = preStyled ? line : TextCell.fit(line, inner)
            let padding = max(0, inner - TextCell.width(plain(text)))
            out.append(left + accent("│") + " " + text + String(repeating: " ", count: padding) + " " + accent("│"))
        }
        out.append(left + accent("└" + String(repeating: "─", count: inner + 2) + "┘"))
        return out
    }

    /// Box text is untrusted: titles and bodies quote folder names back at the
    /// user, and one carrying an escape sequence would drive the terminal.
    /// `TextCell.sanitize` answers "?" for an empty name, which a blank
    /// separator line in a modal is not.
    private func clean(_ text: String) -> String {
        text.isEmpty ? "" : TextCell.sanitize(text)
    }

    private func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

private extension TUITarget {
    /// The node behind a folder target — results rows are always folders.
    var folderNode: FSNode? {
        if case .folder(let node) = self { return node }
        return nil
    }
}
