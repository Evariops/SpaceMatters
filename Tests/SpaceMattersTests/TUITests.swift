import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-15 — the terminal UI. Everything but the file descriptors is pure, so
/// the parts that can go wrong unseen are tested as values: the key grammar, a
/// selection that must follow its folder while rows re-sort under a live scan,
/// frames that must never be wider than the terminal — and, since phase 1, the
/// confirmations standing between a keystroke and a deletion.
@Suite struct TUITests {

    // MARK: Fixtures

    private func leaf(_ name: String, in parent: FSNode?, bytes: Int64, files: Int64 = 1) -> FSNode {
        let node = FSNode(name: name, parent: parent)
        node.finishScan(children: [], filesLogical: bytes, filesPhysical: bytes, fileCount: files)
        node.aggPhysical.store(bytes, ordering: .relaxed)
        node.fileCount.store(files, ordering: .relaxed)
        return node
    }

    /// `root` (300 B of its own files) → `big` (1000) ⊃ `inner` (400), `small` (100)
    private func fixture() -> FSNode {
        let root = FSNode(name: "root", parent: nil)
        let big = FSNode(name: "big", parent: root)
        let inner = leaf("inner", in: big, bytes: 400)
        big.finishScan(children: [inner], filesLogical: 600, filesPhysical: 600, fileCount: 2)
        big.aggPhysical.store(1000, ordering: .relaxed)
        let small = leaf("small", in: root, bytes: 100)
        root.finishScan(children: [small, big], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        root.aggPhysical.store(1400, ordering: .relaxed)
        return root
    }

    private func names(_ rows: [TUIBrowser.Row]) -> [String] {
        rows.map { row -> String in
            switch row {
            case .folder(let node): return node.name
            case .file(let file): return file.name
            case .ownFiles: return "[files]"
            case .moreFiles: return "[more]"
            }
        }
    }

    /// Drop SGR / erase sequences; anything else starting with ESC stays, so a
    /// leak from a file name is still visible to the assertion.
    private func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[mK]", with: "", options: .regularExpression)
    }

    /// The highlighted row, without its padding.
    private func selectedName(_ frame: [String]) -> String? {
        frame.first { $0.contains("\u{1B}[7m") }.map { plain($0).trimmingCharacters(in: .whitespaces) }
    }

    private func text(_ frame: [String]) -> String { frame.map(plain).joined(separator: "\n") }

    /// An app parked in the browser on `tree`, ready for keys.
    private func browse(_ tree: FSNode, host: FakeHost = FakeHost()) -> (TUIApp, FakeHost) {
        host.tree = tree
        let app = TUIApp(host: host)
        app.open(path: "/scan")
        app.refresh()
        return (app, host)
    }

    /// Keys as the frame loop applies them: one at a time, each followed by the
    /// refresh that would precede the next frame.
    @discardableResult
    private func press(_ app: TUIApp, _ keys: [TerminalKey]) -> Bool {
        var open = true
        for key in keys where open {
            open = app.apply(key)
            app.refresh()
        }
        return open
    }

    // MARK: Keys

    @Test func decodesArrowsInBothCursorModes() {
        #expect(Terminal.decode(Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)) == [.up, .down, .right, .left])
        #expect(Terminal.decode(Array("\u{1B}OA\u{1B}OB".utf8)) == [.up, .down])
    }

    @Test func decodesTildeKeysAndIgnoresModifiers() {
        #expect(Terminal.decode(Array("\u{1B}[5~\u{1B}[6~\u{1B}[1~\u{1B}[4~".utf8)) == [.pageUp, .pageDown, .home, .end])
        #expect(Terminal.decode(Array("\u{1B}[1;5A".utf8)) == [.up])
        // `fn⌫` — bound to "move to Trash", so it must decode, not vanish.
        #expect(Terminal.decode(Array("\u{1B}[3~".utf8)) == [.delete])
    }

    @Test func decodesPlainBytesAndTypedText() {
        #expect(Terminal.decode([0x71, 0x0D, 0x7F, 0x03]) == [.char("q"), .enter, .backspace, .interrupt])
        #expect(Terminal.decode([0x1B]) == [.escape])
        #expect(Terminal.decode([0x09]) == [.tab])
        // A path or a search pattern can hold anything a keyboard produces.
        #expect(Terminal.decode(Array("é€".utf8)) == [.char("é"), .char("€")])
    }

    @Test func truncatedSequenceIsDroppedNotMisread() {
        // `ESC [ 1 ;` cut by the read must not come out as `[`, `1`, `;` keystrokes.
        #expect(Terminal.decode(Array("j\u{1B}[1;".utf8)) == [.char("j")])
    }

    // MARK: Rows & navigation

    @Test func rowsRankOwnFilesAmongFolders() {
        let browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        #expect(names(browser.rows()) == ["big", "[files]", "small"])
    }

    @Test func filesAreListedOneByOneWhenTheHostCanReadThem() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        browser.filesProvider = { _ in [TUIFile(name: "a.bin", bytes: 250, apparent: 250),
                                        TUIFile(name: "b.bin", bytes: 50, apparent: 50)] }
        browser.refreshListing()
        // 3 own files, 2 of them listed: the rest stays visible as a remainder.
        #expect(names(browser.rows()) == ["big", "a.bin", "small", "b.bin", "[more]"])
        #expect(browser.rows().last == .moreFiles(count: 1, bytes: 0))
        // Nothing listed (a VM scan, or a listing still on its way): one aggregate.
        var plainBrowser = TUIBrowser(root: fixture(), rootPath: "/scan")
        plainBrowser.refreshListing()
        #expect(names(plainBrowser.rows()).contains("[files]"))
    }

    @Test func selectionFollowsItsFolderWhenRowsResort() {
        let root = fixture()
        var browser = TUIBrowser(root: root, rootPath: "/scan")
        _ = browser.apply(.end)
        #expect(names(browser.rows()).last == "small")
        // A live scan grows `small` past everything else: it moves to the top,
        // and the highlight must move with it.
        let small = root.children.first { $0.name == "small" }!
        small.aggPhysical.store(5000, ordering: .relaxed)
        #expect(names(browser.rows()).first == "small")
        #expect(selectedName(browser.body(width: 100, height: 10, types: []))?.hasSuffix("small/") == true)
    }

    @Test func openAndBackReturnToTheFolderLeft() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        _ = browser.apply(.enter)
        #expect(browser.current.name == "big")
        #expect(browser.currentPath == "/scan/big")
        _ = browser.apply(.left)
        #expect(browser.current.name == "root")
        #expect(selectedName(browser.body(width: 100, height: 10, types: []))?.hasSuffix("big/") == true)
    }

    @Test func sortCyclesThroughTheFourRankings() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        #expect(browser.sort == .size)
        _ = browser.apply(.char("s"))
        #expect(browser.sort == .name)
        #expect(names(browser.rows()).first == "big") // alphabetical, not 1000 B first
        _ = browser.apply(.char("s"))
        #expect(browser.sort == .files)
        _ = browser.apply(.char("s"))
        #expect(browser.sort == .written)
        _ = browser.apply(.char("s"))
        #expect(browser.sort == .size)
    }

    @Test func leavingTheRootGoesHomeInsteadOfNowhere() {
        let (app, host) = browse(fixture())
        #expect(app.route == .browser)
        press(app, [.left])
        #expect(app.route == .home)
        #expect(host.wentHome == 1)
    }

    // MARK: Deleting

    @Test func trashAsksFirstThenRemovesWhatWasSelected() {
        let (app, host) = browse(fixture())
        press(app, [.char("d")])
        guard case .confirm(let confirm)? = app.overlay else {
            Issue.record("no confirmation"); return
        }
        #expect(confirm.title.contains("Trash"))
        #expect(host.deletions.isEmpty) // nothing happened on the mere keystroke
        press(app, [.enter])
        #expect(host.deletions.count == 1)
        #expect(host.deletions[0].name == "big")
        #expect(host.deletions[0].permanently == false)
    }

    @Test func permanentDeleteWillNotTakeReturnForAnAnswer() {
        let (app, host) = browse(fixture())
        press(app, [.char("D")])
        guard case .confirm(let confirm)? = app.overlay else {
            Issue.record("no confirmation"); return
        }
        #expect(confirm.danger)
        #expect(confirm.requiresYes)
        // ⏎ is muscle memory; it must not be enough here.
        press(app, [.enter])
        #expect(host.deletions.isEmpty)
        #expect(app.overlay != nil)
        press(app, [.char("y")])
        #expect(host.deletions.map(\.permanently) == [true])
    }

    @Test func escapeCancelsAndSaysSo() {
        let (app, host) = browse(fixture())
        press(app, [.char("d"), .escape])
        #expect(host.deletions.isEmpty)
        #expect(app.overlay == nil)
        #expect(text(app.render(width: 100, height: 12)).contains("Cancelled"))
    }

    @Test func deletingIsRefusedMidScan() {
        // The scanner's workers are still writing these aggregates.
        let host = FakeHost()
        host.phase = .scanning
        let (app, _) = browse(fixture(), host: host)
        press(app, [.char("d")])
        #expect(host.deletions.isEmpty)
        #expect(app.overlay == nil)
        #expect(text(app.render(width: 100, height: 12)).contains("Wait for the scan"))
    }

    @Test func deletingIsRefusedOnAScanThatIsNotThisMachine() {
        let host = FakeHost()
        host.isHostScan = false
        let (app, _) = browse(fixture(), host: host)
        press(app, [.char("d")])
        #expect(host.deletions.isEmpty)
        #expect(text(app.render(width: 100, height: 12)).contains("read-only"))
    }

    @Test func theRootOfTheScanIsNotADeletionTarget() {
        let root = fixture()
        let (app, host) = browse(root)
        // Stand inside `big`, select its own root row by walking back out: the
        // selection is a child, never the root the trail starts at.
        press(app, [.enter, .left, .char("d"), .enter])
        #expect(host.deletions.map(\.name) == ["big"])
    }

    @Test func aFinishedDeleteReconcilesTheScreens() {
        let root = fixture()
        let (app, host) = browse(root)
        press(app, [.enter]) // into `big`
        #expect(text(app.render(width: 100, height: 12)).contains("inner/"))
        // The folder we are standing in is removed under us — what the host
        // does once the controller has detached it from the tree.
        let big = root.children.first { $0.name == "big" }!
        root.removeChild(big)
        host.notes.append("Moved to Trash — big (1000 B)")
        app.refresh()
        let frame = text(app.render(width: 100, height: 12))
        #expect(frame.contains("Moved to Trash"))
        #expect(!frame.contains("inner/")) // no longer standing inside the deleted subtree
    }

    @Test func deletingAFileTargetsTheFileNotItsFolder() {
        let host = FakeHost()
        host.files = [TUIFile(name: "huge.bin", bytes: 5000, apparent: 5000)]
        let (app, _) = browse(fixture(), host: host)
        press(app, [.char("g"), .char("d"), .enter]) // top row is the 5000 B file
        #expect(host.deletions.map(\.name) == ["huge.bin"])
    }

    @Test func resultsDropHitsWhoseAncestorWasDeleted() {
        let root = fixture()
        let (app, host) = browse(root)
        press(app, [.char("T")])            // largest folders: big, inner, small
        #expect(text(app.render(width: 100, height: 12)).contains("inner"))
        // `big` goes; `inner` is still a live object (the results hold it) but
        // it is no longer in the tree.
        let big = root.children.first { $0.name == "big" }!
        root.removeChild(big)
        host.notes.append("Moved to Trash — big (1000 B)")
        app.refresh()
        let frame = text(app.render(width: 100, height: 12))
        #expect(!frame.contains("inner"))
        #expect(frame.contains("small"))
    }

    @Test func goingToADeletedResultSaysSoInsteadOfCrashing() {
        let root = fixture()
        let (app, host) = browse(root)
        press(app, [.char("T")])
        let big = root.children.first { $0.name == "big" }!
        root.removeChild(big)               // deleted, but the results still hold it
        _ = host                            // no note: the screens have not reconciled yet
        press(app, [.enter])
        #expect(app.route == .results)
        #expect(text(app.render(width: 100, height: 12)).contains("no longer in the scan"))
    }

    @Test func escapeWalksUpBeforeItLeavesTheScan() {
        let (app, host) = browse(fixture())
        press(app, [.enter])                 // into `big`
        press(app, [.escape])
        #expect(app.route == .browser)       // still in the scan, one level up
        #expect(host.wentHome == 0)
        press(app, [.escape])
        #expect(app.route == .home)
    }

    // MARK: Cleanup

    @Test func cleanupNeedsAPickAndThenAConfirmation() {
        let host = FakeHost()
        host.cleanup = TUICleanupState(
            phase: .ready,
            rows: [TUICleanupRow(id: "npm", name: "npm cache", category: "Package managers",
                                 note: "rebuilt on next install", nativeLabel: nil, regenerable: true,
                                 size: .sized(2 << 30), selected: false)])
        let app = TUIApp(host: host)
        app.start(.cleanup)
        app.refresh()

        press(app, [.enter]) // nothing ticked yet
        #expect(host.cleaned == 0)
        #expect(text(app.render(width: 100, height: 12)).contains("Nothing picked"))

        press(app, [.char(" ")])
        #expect(host.toggled == ["npm"])
        host.cleanup.rows[0].selected = true
        app.refresh()

        press(app, [.enter])
        guard case .confirm(let confirm)? = app.overlay else {
            Issue.record("no confirmation"); return
        }
        #expect(confirm.requiresYes)
        #expect(confirm.lines.joined().contains("npm cache"))
        press(app, [.char("y")])
        #expect(host.cleaned == 1)
    }

    @Test func cleaningIsRefusedWhileTheSizesAreStillComing() {
        let host = FakeHost()
        host.cleanup = TUICleanupState(phase: .sizing, rows: [])
        let app = TUIApp(host: host)
        app.start(.cleanup)
        app.refresh()
        press(app, [.enter])
        #expect(host.cleaned == 0)
        #expect(text(app.render(width: 100, height: 12)).contains("Still measuring"))
    }

    @Test func cleanupShowsWhyARowCannotBeTicked() {
        var screen = TUICleanupScreen()
        screen.state = TUICleanupState(phase: .ready, rows: [
            TUICleanupRow(id: "go-mod", name: "Go modules", category: "Toolchains", note: "",
                          nativeLabel: nil, regenerable: true,
                          size: .blocked("needs the Go toolchain"), selected: false),
            TUICleanupRow(id: "trash", name: "Trash", category: "System", note: "emptying is forever",
                          nativeLabel: nil, regenerable: false, size: .sized(1 << 30), selected: false),
        ])
        let body = screen.body(width: 120, height: 10).map(plain).joined(separator: "\n")
        #expect(body.contains("needs the Go toolchain"))
        #expect(body.contains("not regenerable"))
    }

    // MARK: Home, find, menu

    @Test func homeListsEverythingItFoundAndStartsIt() {
        let host = FakeHost()
        host.sources = TUISources(
            volumes: [Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", total: 1000,
                             available: 400, isInternal: true, isRemovable: false, isRoot: true)],
            machines: [], contexts: [K8sContext(name: "dev", isCurrent: true)], engines: [], loaded: true)
        let app = TUIApp(host: host)
        app.refresh()
        let frame = text(app.render(width: 100, height: 20))
        #expect(frame.contains("Macintosh HD"))
        #expect(frame.contains("Low-Hanging Fruits"))
        #expect(frame.contains("dev"))
        press(app, [.enter])
        #expect(host.started == ["volume:/"])
        #expect(app.route == .browser)
    }

    @Test func aPathTypedInTheHomeMenuIsCheckedBeforeItIsScanned() {
        let host = FakeHost()
        let app = TUIApp(host: host)
        app.refresh()
        press(app, [.char("/")])
        guard case .prompt? = app.overlay else { Issue.record("no prompt"); return }
        press(app, [.char("/"), .char("n"), .char("o"), .char("p"), .char("e"), .enter])
        #expect(host.started.isEmpty)
        #expect(text(app.render(width: 100, height: 12)).contains("No folder at /nope"))
    }

    @Test func findWalksTheTreeAndItsHitsCanBeDeleted() {
        let (app, host) = browse(fixture())
        press(app, [.char("/")])
        guard case .prompt? = app.overlay else { Issue.record("no prompt"); return }
        press(app, [.char("i"), .char("n"), .char("n"), .enter])
        #expect(app.route == .results)
        let frame = text(app.render(width: 100, height: 12))
        #expect(frame.contains("inner"))
        #expect(frame.contains("1 folder"))
        // A hit deletes through the same confirmation as a row in the browser.
        press(app, [.char("d"), .enter])
        #expect(host.deletions.map(\.name) == ["inner"])
    }

    @Test func aResultWalksTheBrowserToIt() {
        let (app, _) = browse(fixture())
        press(app, [.char("T")]) // largest folders in here
        #expect(app.route == .results)
        press(app, [.enter])
        #expect(app.route == .browser)
        // `big` is the largest; the browser is now standing in it.
        #expect(text(app.render(width: 100, height: 12)).contains("/scan/big"))
    }

    @Test func theMenuRunsTheSameRequestsAsTheKeysDo() {
        let (app, host) = browse(fixture())
        press(app, [.char("m")])
        guard case .menu(let menu)? = app.overlay else { Issue.record("no menu"); return }
        #expect(menu.items.contains { $0.label.contains("Trash") })
        // The menu doubles as a legend: its key runs the entry.
        press(app, [.char("d")])
        guard case .confirm? = app.overlay else { Issue.record("menu did not run the entry"); return }
        press(app, [.enter])
        #expect(host.deletions.count == 1)
    }

    @Test func quittingWhileSomethingIsRunningAsksFirst() {
        let host = FakeHost()
        host.busy = "Emptying 3 targets…"
        let (app, _) = browse(fixture(), host: host)
        #expect(press(app, [.interrupt])) // refused: a job is in flight
        #expect(app.wantsToQuit == false)
        guard case .confirm? = app.overlay else { Issue.record("no confirmation"); return }
        press(app, [.char("y")])
        #expect(app.wantsToQuit)
    }

    @Test func quittingWithNothingRunningJustQuits() {
        let (app, _) = browse(fixture())
        press(app, [.left])              // back to the home menu
        #expect(app.apply(.char("q")) == false)
    }

    @Test func helpIsOneKeyAwayAndClosesOnAnyKey() {
        let (app, _) = browse(fixture())
        press(app, [.char("?")])
        #expect(text(app.render(width: 100, height: 20)).contains("DELETE"))
        press(app, [.escape])
        #expect(app.overlay == nil)
    }

    // MARK: Frames

    @Test func framesFitAnyTerminal() {
        // Every overlay and panel, at every size that could clip.
        let openings: [[TerminalKey]] = [[], [.char("t")], [.char("?")], [.char("m")],
                                         [.char("d")], [.char("D")], [.char("/")], [.char("i")],
                                         [.char("T")], [.char("A")]]
        for width in [1, 12, 23, 30, 49, 63, 80, 140] {
            for height in [1, 3, 4, 8, 30] {
                for keys in openings {
                    let root = fixture()
                    // Wide characters, a combining accent, an emoji: what a
                    // Character count gets wrong and a terminal draws two cells
                    // wide (or none).
                    let tricky = leaf("日本語のフォルダ-cafe\u{301}-📦-with-a-rather-long-name", in: root, bytes: 50)
                    root.finishScan(children: root.children + [tricky],
                                    filesLogical: 300, filesPhysical: 300, fileCount: 3)
                    let host = FakeHost()
                    host.files = [TUIFile(name: "an-emoji-📦-file.bin", bytes: 40, apparent: 40)]
                    let (app, _) = browse(root, host: host)
                    press(app, keys)
                    let frame = app.render(width: width, height: height)
                    #expect(frame.count == height, "\(width)×\(height) \(keys)")
                    for line in frame {
                        #expect(TextCell.width(plain(line)) <= width,
                                "\(width)×\(height) \(keys): \(plain(line))")
                    }
                }
            }
        }
    }

    @Test func theOtherScreensFitTheirTerminalToo() {
        let host = FakeHost()
        host.cleanup = TUICleanupState(phase: .ready, rows: [
            TUICleanupRow(id: "npm", name: "npm cache", category: "Package managers",
                          note: "rebuilt on the next install, every byte of it",
                          nativeLabel: "pnpm store prune", regenerable: true,
                          size: .sized(3 << 30), selected: true)])
        host.table = sampleTable()
        for width in [1, 20, 40, 80, 140] {
            for height in [1, 5, 24] {
                let cleanup = TUIApp(host: host)
                cleanup.start(.cleanup)
                cleanup.refresh()
                var frame = cleanup.render(width: width, height: height)
                #expect(frame.count == height)
                for line in frame {
                    #expect(TextCell.width(plain(line)) <= width, "cleanup \(width)×\(height): \(plain(line))")
                }

                let table = TUIApp(host: host)
                table.start(.kubernetes("dev"))
                table.refresh()
                frame = table.render(width: width, height: height)
                #expect(frame.count == height)
                for line in frame {
                    #expect(TextCell.width(plain(line)) <= width, "table \(width)×\(height): \(plain(line))")
                }

                let home = TUIApp(host: host)
                home.refresh()
                frame = home.render(width: width, height: height)
                #expect(frame.count == height)
                for line in frame {
                    #expect(TextCell.width(plain(line)) <= width, "home \(width)×\(height): \(plain(line))")
                }
            }
        }
    }

    private func sampleTable() -> TUITable {
        var table = TUITable()
        table.title = "Kubernetes — dev"
        table.subtitle = "2 PVCs · 20 GiB provisioned · 4 GiB used"
        table.columns = [
            .init(title: "capacity", width: 10, alignRight: true),
            .init(title: "used", width: 10, alignRight: true, priority: 1),
            .init(title: "class", width: 16, priority: 3),
            .init(title: "namespace/name", width: 0),
        ]
        table.rows = [
            .init(cells: ["10 GiB", "4 GiB", "fast-ssd", "default/data-0"], fraction: 0.4),
            .init(cells: ["10 GiB", "—", "fast-ssd", "kube-system/registry"], fraction: nil, dim: true),
        ]
        table.footnote = "Read-only here."
        return table
    }

    @Test func fileNamesCannotDriveTheTerminal() {
        let root = fixture()
        let hostile = leaf("evil\u{1B}]0;pwned\u{07}\u{1B}[2J", in: root, bytes: 5000)
        root.finishScan(children: root.children + [hostile], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        let host = FakeHost()
        host.files = [TUIFile(name: "also\u{1B}]0;evil\u{07}.bin", bytes: 10, apparent: 10)]
        let (app, _) = browse(root, host: host)
        let frame = app.render(width: 100, height: 14)
        #expect(!frame.map(plain).joined().contains("\u{1B}"))
        #expect(!frame.joined().contains("\u{07}"))
        // Even inside a modal, where the name is quoted back at you.
        press(app, [.char("i")])
        #expect(!app.render(width: 100, height: 14).map(plain).joined().contains("\u{1B}"))
        press(app, [.escape, .char("d")])
        #expect(!app.render(width: 100, height: 14).map(plain).joined().contains("\u{1B}"))
    }

    @Test func liveFolderIsMarkedAndEmptyFolderSaysSo() {
        let root = FSNode(name: "root", parent: nil)
        let pending = FSNode(name: "pending", parent: root)
        root.appendChild(pending)
        let host = FakeHost()
        host.phase = .scanning
        let (app, _) = browse(root, host: host)
        let frame = app.render(width: 100, height: 8).map(plain)
        #expect(frame[0].contains("scanning"))
        #expect(frame.contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("pending/ …") })
        press(app, [.enter])
        #expect(app.render(width: 100, height: 8).map(plain).contains { $0.contains("(scanning…)") })
    }

    @Test func aRunningJobIsNamedInTheHeader() {
        let host = FakeHost()
        host.busy = "Moving node_modules…"
        let (app, _) = browse(fixture(), host: host)
        #expect(text(app.render(width: 100, height: 8)).contains("Moving node_modules…"))
    }

    // MARK: Text cells

    @Test func cellWidths() {
        #expect(TextCell.width("abc") == 3)
        #expect(TextCell.width("日本") == 4)
        #expect(TextCell.width("cafe\u{301}") == 4)
        #expect(TextCell.width("📦") == 2)
    }

    @Test func fittingCutsWithAnEllipsis() {
        #expect(TextCell.fit("abcdef", 4) == "abc…")
        #expect(TextCell.fit("abc", 4) == "abc")
        #expect(TextCell.fit("日本語", 4) == "日…")
        #expect(TextCell.fitLeading("/very/long/path", 6) == "…/path")
    }

    @Test func wrappingKeepsWholeWords() {
        #expect(TextCell.wrap("one two three", 8) == ["one two", "three"])
        #expect(TextCell.wrap("supercalifragilistic", 6) == ["super…"])
    }

    @Test func barsAreExactWidth() {
        #expect(TextCell.bar(0, width: 10) == String(repeating: " ", count: 10))
        #expect(TextCell.bar(1, width: 10) == String(repeating: "█", count: 10))
        #expect(TextCell.bar(0.55, width: 10).hasPrefix("█████▌"))
        for step in 0...20 {
            #expect(TextCell.width(TextCell.bar(Double(step) / 20, width: 10)) == 10)
        }
    }
}

// MARK: - Fake host

/// A [TUIHost](x-source-tag://TUIHost) with no disk, no `kubectl` and no Trash
/// behind it: it records what the interface asked for. Every destructive test
/// in this suite asserts against these counters — the real host is what turns
/// them into deletions, and it has the controllers' own guards under it.
final class FakeHost: TUIHost {

    var tree: FSNode?
    var phase: TUIStatus.Phase = .ready
    var isHostScan = true
    var busy: String?
    var files: [TUIFile] = []
    var sources = TUISources(loaded: true)
    var cleanup = TUICleanupState()
    var table: TUITable?
    var notes: [String] = []

    // What the interface asked for.
    private(set) var deletions: [(name: String, permanently: Bool)] = []
    private(set) var started: [String] = []
    private(set) var toggled: [String] = []
    private(set) var cleaned = 0
    private(set) var rescanned: [String] = []
    private(set) var wentHome = 0
    private(set) var briefings = 0
    private(set) var reloads = 0

    var status: TUIStatus {
        var status = TUIStatus()
        status.phase = phase
        status.rootName = tree?.name ?? ""
        status.rootPath = "/scan"
        status.onDisk = tree?.sizeOnDisk ?? 0
        status.files = tree?.fileCount.load(ordering: .relaxed) ?? 0
        status.isHostScan = isHostScan
        status.canDelete = isHostScan && phase != .scanning && busy == nil
        status.busy = busy
        status.types = [ExtRow(key: ExtKey(fileName: "a.bin"), name: "bin",
                               logical: 300, physical: 300, count: 3)]
        return status
    }

    var root: FSNode? { tree }

    func takeNote() -> String? { notes.isEmpty ? nil : notes.removeFirst() }
    func reloadSources() { reloads += 1 }

    func start(_ source: TUISource) {
        switch source {
        case .volume(let volume): started.append("volume:" + volume.url.path)
        case .path(let path): started.append("path:" + path)
        case .vm(let machine, let scope): started.append("vm:\(machine.id):\(scope.rawValue)")
        case .cleanup: started.append("cleanup")
        case .kubernetes(let context): started.append("k8s:" + context)
        case .containers(let id): started.append("containers:" + id)
        }
    }

    func goHome() { wentHome += 1 }
    func rescanAll() { rescanned.append("*") }
    func rescan(_ node: FSNode) { rescanned.append(node.name) }
    func cancelScan() {}

    func files(in node: FSNode) -> [TUIFile] { node.directFileCount > 0 ? files : [] }
    func path(of node: FSNode) -> String? { "/scan/" + node.name }

    func delete(_ target: TUITarget, permanently: Bool) {
        deletions.append((target.name, permanently))
    }

    func copyBriefing() { briefings += 1 }
    func reveal(_ path: String) {}
    func open(_ path: String) {}

    func loadCleanup() {}
    func toggleCleanup(_ id: String) { toggled.append(id) }
    func toggleAllCleanup() { toggled.append("*") }
    func cleanSelected() { cleaned += 1 }

    func loadTable(_ kind: TUITableKind) {}
    func table(_ kind: TUITableKind) -> TUITable? { table }
}
