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
            switch row.kind {
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

    private func keys(_ text: String) -> [TerminalKey] { Terminal.decode(Array(text.utf8)).keys }

    @Test func decodesArrowsInBothCursorModes() {
        #expect(keys("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D") == [.up, .down, .right, .left])
        #expect(keys("\u{1B}OA\u{1B}OB") == [.up, .down])
    }

    @Test func decodesTildeKeysAndIgnoresModifiers() {
        #expect(keys("\u{1B}[5~\u{1B}[6~\u{1B}[1~\u{1B}[4~") == [.pageUp, .pageDown, .home, .end])
        #expect(keys("\u{1B}[1;5A") == [.up])
        // `fn⌫` — bound to "move to Trash", so it must decode, not vanish.
        #expect(keys("\u{1B}[3~") == [.delete])
    }

    @Test func decodesPlainBytesAndTypedText() {
        #expect(Terminal.decode([0x71, 0x0D, 0x7F, 0x03]).keys == [.char("q"), .enter, .backspace, .interrupt])
        #expect(Terminal.decode([0x09]).keys == [.tab])
        // A path or a search pattern can hold anything a keyboard produces.
        #expect(keys("é€") == [.char("é"), .char("€")])
    }

    @Test func aCutSequenceIsCarriedOverNotMisread() {
        // `ESC [ 1 ;` cut by the read must not come out as `[`, `1`, `;`
        // keystrokes — it is handed back to be finished by the next read.
        let first = Terminal.decode(Array("j\u{1B}[1;".utf8))
        #expect(first.keys == [.char("j")])
        #expect(first.remainder == Array("\u{1B}[1;".utf8))
        #expect(Terminal.decode(first.remainder + Array("5A".utf8)).keys == [.up])
        // A lone ESC at the end of a read is held back too: it is only an
        // `Esc` once nothing follows it.
        #expect(Terminal.decode([0x1B]).keys.isEmpty)
        #expect(Terminal.decode([0x1B]).remainder == [0x1B])
    }

    @Test func metaKeysAreNotReadAsEscape() {
        // Option-as-Meta sends `ESC q`. Decoding that as Esc + q would quit the
        // browser on a key nobody pressed.
        #expect(keys("\u{1B}q").isEmpty)
        #expect(keys("\u{1B}qj") == [.char("j")])
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
        #expect(browser.rows().last?.kind == .moreFiles(count: 1))
        // Nothing listed (a VM scan, or a listing still on its way): one aggregate.
        var plainBrowser = TUIBrowser(root: fixture(), rootPath: "/scan")
        plainBrowser.refreshListing()
        #expect(names(plainBrowser.rows()).contains("[files]"))
    }

    /// The host lists a folder's files off the main actor and answers `[]`
    /// until they land. That first empty answer must not stick: the files show
    /// as soon as they arrive, on the first visit.
    @Test func filesShowOnTheFirstVisitWhenTheListingLandsLate() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        var answers = 0
        browser.filesProvider = { _ in
            answers += 1
            return answers == 1 ? [] : [TUIFile(name: "a.bin", bytes: 250, apparent: 250)]
        }
        browser.refreshListing()
        #expect(!names(browser.rows()).contains("a.bin"))
        browser.refreshListing() // the next frame
        #expect(names(browser.rows()).contains("a.bin"))
    }

    /// A compressed file's gap is compression, not holes — on screen, and in
    /// what a delete subtracts from the folders above it.
    @Test func aCompressedFileIsNotCalledSparse() {
        let file = TUIFile(name: "zeros.txt", bytes: 4096, apparent: 64 << 20, compressed: true)
        #expect(file.divergence?.label == "compressed")
        let sparse = TUIFile(name: "disk.img", bytes: 4096, apparent: 64 << 20)
        #expect(sparse.divergence?.label == "sparse")
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

    /// One "up" too many at the root must not throw away a scan: it is the
    /// most-used key, and the `h` of a paste. It asks; ⏎ closes, esc stays.
    @Test func leavingTheRootAsksBeforeDiscardingTheScan() {
        let (app, host) = browse(fixture())
        #expect(app.route == .browser)
        press(app, [.left])
        guard case .confirm(let confirm)? = app.overlay else { Issue.record("no confirmation"); return }
        #expect(confirm.title == "Close this scan?")
        #expect(!confirm.requiresYes)
        #expect(host.wentHome == 0)
        press(app, [.escape])
        #expect(app.route == .browser)       // stayed, scan intact
        press(app, [.char("q"), .enter])
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

    /// Round 2's blocking finding, as values. A burst — a paste in a terminal
    /// without bracketed paste, or keys typed ahead while the loop was busy —
    /// stops at the key that opens a confirmation, and nothing after it may
    /// answer it. Once the question is up, a burst is refused whole; one key
    /// read on its own answers.
    @Test func aBurstCannotAnswerTheConfirmationItOpened() {
        for burst in ["Do you have a minute?\r", "cd ~/foo\r", "Dy"] {
            let (app, host) = browse(fixture())
            #expect(app.apply(batch: keys(burst)) == .awaitAnswer, "\(burst)")
            #expect(app.isConfirming, "\(burst)")
            #expect(host.deletions.isEmpty, "\(burst)")
        }
        let (app, host) = browse(fixture())
        #expect(app.apply(batch: [.char("D")]) == .awaitAnswer)
        #expect(app.apply(batch: [.char("y"), .char("y")]) == .awaitAnswer)
        #expect(host.deletions.isEmpty)
        #expect(app.isConfirming)
        #expect(app.apply(batch: [.char("y")]) == .keepGoing)
        #expect(host.deletions.map(\.permanently) == [true])
    }

    /// With bracketed paste on, a paste is text, never keys — and a paste far
    /// longer than one read, its end marker cut by the read, leaks nothing.
    @Test func aBracketedPasteIsTextNotKeys() {
        #expect(Terminal.decode(Array("x\u{1B}[200~Dy\r\u{1B}[201~j".utf8)).keys
                == [.char("x"), .paste("Dy\r"), .char("j")])
        var pasting = false
        let first = Terminal.decode(Array("\u{1B}[200~rm -rf ~\u{1B}[20".utf8), pasting: &pasting)
        #expect(first.keys == [.paste("rm -rf ~")])
        #expect(pasting)
        #expect(first.remainder == Array("\u{1B}[20".utf8))
        let second = Terminal.decode(first.remainder + Array("1~q".utf8), pasting: &pasting)
        #expect(second.keys == [.char("q")])
        #expect(!pasting)
    }

    /// Only a text field takes a paste, one line of it; anywhere else it is
    /// dropped whole, because its letters are commands there.
    @Test func aPasteOnlyGoesIntoATextField() {
        let (app, host) = browse(fixture())
        _ = app.apply(.paste("Dy"))
        #expect(!app.isConfirming)
        #expect(host.deletions.isEmpty)
        press(app, [.char("/")])
        _ = app.apply(.paste("node_\nmodules\u{1B}"))
        guard case .prompt(let prompt)? = app.overlay else { Issue.record("no prompt"); return }
        #expect(prompt.value == "node_modules")
    }

    /// Ctrl-Z arrives as a byte in raw mode; it stops the app like it stops
    /// anything else in a shell, and nothing typed after it runs.
    @Test func ctrlZSuspends() {
        #expect(keys("\u{1A}") == [.suspend])
        let (app, _) = browse(fixture())
        #expect(app.apply(batch: [.suspend, .char("D")]) == .suspend)
        #expect(!app.isConfirming)
    }

    /// A folder the scanner could not read has no size: the question must not
    /// say "0 B", and a permanent delete of something never seen is refused.
    @Test func aFolderNeverReadIsNotAskedAboutAsEmpty() {
        let root = FSNode(name: "root", parent: nil)
        let big = leaf("big", in: root, bytes: 1000)
        let locked = leaf("locked", in: root, bytes: 0, files: 0)
        locked.markUnreadable()
        root.finishScan(children: [big, locked], filesLogical: 0, filesPhysical: 0, fileCount: 0)
        root.aggPhysical.store(1000, ordering: .relaxed)
        let (app, host) = browse(root)

        press(app, [.down, .char("D")])
        #expect(!app.isConfirming)
        #expect(text(app.render(width: 120, height: 12)).contains("never read"))
        press(app, [.char("d")])
        guard case .confirm(let confirm)? = app.overlay else { Issue.record("no confirmation"); return }
        #expect(confirm.lines.first == "Size unknown — this folder was never read")
        #expect(!confirm.lines.contains { $0.contains("0 B") })
        #expect(host.deletions.isEmpty)
    }

    /// After a stopped scan every folder total is a floor, and the question
    /// says so rather than state it as the size.
    @Test func aStoppedScanAsksWithALowerBound() {
        let host = FakeHost()
        host.phase = .cancelled
        let (app, _) = browse(fixture(), host: host)
        press(app, [.char("d")])
        guard case .confirm(let confirm)? = app.overlay else { Issue.record("no confirmation"); return }
        #expect(confirm.lines.first?.hasPrefix("At least") == true)
    }

    /// `--tui <path>` never shows the menu at first, so the probes wait for it
    /// rather than hold the job slot meanwhile.
    @Test func aPathGivenUpFrontLeavesTheProbesForTheMenu() {
        let host = FakeHost()
        host.tree = fixture()
        host.sources = TUISources()
        let app = TUIApp(host: host, loadSources: false)
        app.open(path: "/scan")
        app.refresh()
        #expect(host.reloads == 0)
        press(app, [.left, .enter])
        #expect(app.route == .home)
        #expect(host.reloads == 1)
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
        #expect(app.isConfirming)            // at the root: asks before closing the scan
        press(app, [.enter])
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

    /// Discovered targets arrive at the end of the controller's list; on
    /// screen they sit in their own section, which is listed once.
    @Test func cleanupSectionsAreListedOnce() {
        var screen = TUICleanupScreen()
        func row(_ id: String, _ category: String) -> TUICleanupRow {
            TUICleanupRow(id: id, name: id, category: category, note: "n", nativeLabel: nil,
                          regenerable: true, size: .searching, selected: false)
        }
        screen.state.rows = [row("trash", "System"), row("npm", "JavaScript"), row("tmp", "System")]
        let body = text(screen.body(width: 100, height: 20))
        #expect(body.components(separatedBy: "SYSTEM").count == 2)
        #expect(body.range(of: "tmp")!.lowerBound < body.range(of: "JAVASCRIPT")!.lowerBound)
        #expect(body.contains("searching"))
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
        press(app, [.left, .enter])      // back to the home menu, closing the scan
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
        // The thresholds where a column appears (50 bar, 64 written, 76 files)
        // and the cells on either side of each, where an off-by-one shows.
        for width in [1, 12, 23, 24, 30, 49, 50, 51, 63, 64, 65, 75, 76, 77, 80, 140] {
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
        for width in [1, 20, 40, 49, 50, 63, 64, 76, 80, 140] {
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

    // MARK: Output contract

    @Test func aFullWidthLineGetsNoEraseToEndOfLine() {
        // With autowrap off the cursor stays *on* the last column, so ESC[K
        // after a full-width line would erase the cell just drawn.
        let full = String(repeating: "x", count: 10)
        #expect(!Terminal.diff([full], over: [], width: 10, cursorRow: nil).contains("\u{1B}[K"))
        #expect(Terminal.diff(["xx"], over: [], width: 10, cursorRow: nil).contains("\u{1B}[K"))
        // Styles do not count towards the width.
        let styled = "\u{1B}[7m" + full + "\u{1B}[0m"
        #expect(!Terminal.diff([styled], over: [], width: 10, cursorRow: nil).contains("\u{1B}[K"))
    }

    @Test func onlyChangedLinesAreWrittenAndTheCursorIsParked() {
        let before = ["a", "b", "c"]
        let after = ["a", "B", "c"]
        let out = Terminal.diff(after, over: before, width: 40, cursorRow: 1)
        #expect(out.contains("\u{1B}[2;1H"))     // line 2 repainted
        #expect(!out.contains("\u{1B}[1;1H"))    // line 1 untouched
        #expect(out.hasSuffix("\u{1B}[2;1H"))    // cursor parked on the selected row
        #expect(Terminal.diff(before, over: before, width: 40, cursorRow: 0).isEmpty)
        // A shorter frame erases the lines it no longer covers.
        #expect(Terminal.diff(["a"], over: before, width: 40, cursorRow: nil).contains("\u{1B}[3;1H\u{1B}[K"))
    }

    @Test func theLoopStopsRedrawingOnATimerWhenNothingMoves() {
        var status = TUIStatus()
        status.phase = .scanning
        #expect(TUI.tick(for: status) == TUI.liveTickMilliseconds)
        status.phase = .ready
        #expect(TUI.tick(for: status) == TUI.idleTickMilliseconds)
        status.busy = "Moving node_modules…"
        #expect(TUI.tick(for: status) == TUI.liveTickMilliseconds)
    }

    @Test func asciiModeKeepsEveryWidthItReplaces() {
        // The swap must be cell-for-cell: a frame measured before it still
        // fits after it.
        for line in ["  12.4 GiB   48.2%  ████▊  Library/", "↑↓ move   → open   ← up   · ⏎ ⌫ …",
                     "┌─ Keys ─┐", "│ x │"] {
            #expect(TextCell.width(Glyphs.asciify(line)) == TextCell.width(line), "\(line)")
        }
        // Names are data, not chrome: they are left alone.
        #expect(Glyphs.asciify("日本語-café-📦.txt") == "日本語-café-📦.txt")
    }

    // MARK: Golden frames

    @Test func rowsAreDrawnExactlyAsSpecified() {
        // Written out by hand rather than measured with the same function that
        // built them: `TextCell.width` sizing its own output proves internal
        // consistency, not what a terminal draws.
        let root = FSNode(name: "root", parent: nil)
        let docs = leaf("docs", in: root, bytes: 1000, files: 2)
        root.finishScan(children: [docs], filesLogical: 0, filesPhysical: 0, fileCount: 2)
        root.aggPhysical.store(1000, ordering: .relaxed)
        var browser = TUIBrowser(root: root, rootPath: "/scan")

        // 40 cells: size (10) + 2 + share (6) + 2 + name. No bar (< 50), no
        // written column (< 64), no files column (< 76). The selected row is
        // padded to the full width — that is what the highlight fills.
        let narrow = browser.body(width: 40, height: 3, types: []).map(plain)
        #expect(narrow[0] == "   on disk       %  name")
        #expect(narrow[1] == "    1000 B    100%  docs/" + String(repeating: " ", count: 15))
        #expect(narrow[1].count == 40)

        // 80 cells: every column is in — 10 + 2 + 6 + 2 + 10 (bar) + 2 + 11
        // (files) + 2 + 8 (written) + 2 + name = 59 before the padding.
        // `written` reads "—": the fixture carries no mtime, and 0 means
        // unknown, never 1970.
        let wide = browser.body(width: 80, height: 3, types: []).map(plain)
        #expect(wide[0] == "   on disk       %                    files   written  name")
        #expect(wide[1].hasPrefix("    1000 B    100%  ██████████            2         —  docs/"))
        #expect(TextCell.width(wide[1]) == 80)
    }

    @Test func wideAndCombiningNamesAreCutAtTheCellTheyFill() {
        #expect(TextCell.fit("日本語のフォルダ", 8) == "日本語…")        // 3×2 + 1 = 7 cells
        #expect(TextCell.fit("café\u{301}", 4) == "café\u{301}")        // combining mark: no cell
        #expect(TextCell.fit("📦📦📦", 5) == "📦📦…")                   // 2 + 2 + 1 = 5
        #expect(TextCell.displayWidth("\u{1B}[7mabc\u{1B}[0m") == 3)
        #expect(TextCell.displayWidth("\u{1B}[38;5;9m日本\u{1B}[0m") == 4)
    }

    // MARK: Unreadable folders

    @Test func anUnreadableFolderIsNotReportedAsEmpty() {
        let root = FSNode(name: "root", parent: nil)
        let locked = FSNode(name: "locked", parent: root)
        locked.markUnreadable()
        locked.finishScan(children: [], filesLogical: 0, filesPhysical: 0, fileCount: 0)
        root.finishScan(children: [locked], filesLogical: 0, filesPhysical: 0, fileCount: 0)

        let host = FakeHost()
        host.skipped = 1
        let (app, _) = browse(root, host: host)
        let frame = text(app.render(width: 110, height: 10))
        #expect(frame.contains("locked/  (unreadable)"))
        // …and the header says what that does to every total above it.
        #expect(frame.contains("lower bound"))

        // Inside it, "no files" would be a lie.
        press(app, [.enter])
        let inside = text(app.render(width: 110, height: 10))
        #expect(inside.contains("unreadable — permission denied"))
        #expect(inside.contains("Full Disk Access"))
        #expect(!inside.contains("(no files)"))
    }

    @Test func theSelectionIsPinnedBeforeTheFirstKeyPress() {
        let root = fixture()
        let host = FakeHost()
        host.phase = .scanning
        let (app, _) = browse(root, host: host)
        // First frame: the highlight lands on the biggest row, `big`.
        #expect(selectedName(app.render(width: 100, height: 12))?.hasSuffix("big/") == true)
        // The scan then grows `small` past it. Without a pinned selection the
        // highlight would follow "whatever is first now" — under the cursor.
        let small = root.children.first { $0.name == "small" }!
        small.aggPhysical.store(99_999, ordering: .relaxed)
        app.refresh()
        #expect(selectedName(app.render(width: 100, height: 12))?.hasSuffix("big/") == true)
    }

    @Test func oneFileIsNotOneFiles() {
        let root = FSNode(name: "root", parent: nil)
        root.finishScan(children: [], filesLogical: 10, filesPhysical: 10, fileCount: 1)
        root.aggPhysical.store(10, ordering: .relaxed)
        root.fileCount.store(1, ordering: .relaxed)
        let host = FakeHost()
        let (app, _) = browse(root, host: host)
        let frame = text(app.render(width: 110, height: 8))
        #expect(frame.contains("[1 file here]"))
        #expect(!frame.contains("1 files"))
        #expect(!frame.contains("1 folders"))
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

    /// A path keeps every character: broken after a `/`, or mid-name when a
    /// single name is wider than the line.
    @Test func pathsWrapWithoutLosingACharacter() {
        let path = "/tmp/claude-502/-Users-rducom-sources-Evariops-SpaceMatters/be1cd43c/fx/trashme"
        let lines = TextCell.wrapPath(path, 30)
        #expect(lines.joined() == path)
        #expect(lines.allSatisfy { TextCell.width($0) <= 30 })
        #expect(lines.first == "/tmp/claude-502/")
        #expect(TextCell.wrapPath("/a/b", 56) == ["/a/b"])
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
    var skipped: Int64 = 0
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
        status.folders = 1
        status.skipped = skipped
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
