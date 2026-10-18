import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-15 — the terminal browser. Everything but the file descriptors is pure,
/// so the parts that can go wrong unseen are tested as values: the key grammar,
/// a selection that must follow its folder while rows re-sort under a live
/// scan, and frames that must never be wider than the terminal.
@Suite struct TUITests {

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

    private let idle = TUIBrowser.Status(scanning: false, elapsed: 1, files: 6, folders: 4, skipped: 0)

    private func names(_ rows: [TUIBrowser.Row]) -> [String] {
        rows.map { row -> String in
            switch row {
            case .folder(let node): return node.name
            case .ownFiles: return "[files]"
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

    // MARK: Keys

    @Test func decodesArrowsInBothCursorModes() {
        #expect(Terminal.decode(Array("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D".utf8)) == [.up, .down, .right, .left])
        #expect(Terminal.decode(Array("\u{1B}OA\u{1B}OB".utf8)) == [.up, .down])
    }

    @Test func decodesTildeKeysAndIgnoresModifiers() {
        #expect(Terminal.decode(Array("\u{1B}[5~\u{1B}[6~\u{1B}[1~\u{1B}[4~".utf8)) == [.pageUp, .pageDown, .home, .end])
        #expect(Terminal.decode(Array("\u{1B}[1;5A".utf8)) == [.up])
        #expect(Terminal.decode(Array("\u{1B}[3~".utf8)).isEmpty) // Delete: unbound
    }

    @Test func decodesPlainBytes() {
        #expect(Terminal.decode([0x71, 0x0D, 0x7F, 0x03]) == [.char("q"), .enter, .backspace, .interrupt])
        #expect(Terminal.decode([0x1B]) == [.escape])
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
        let frame = browser.render(width: 100, height: 12, status: idle)
        #expect(selectedName(frame)?.hasSuffix("small/") == true)
    }

    @Test func openAndBackReturnToTheFolderLeft() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        _ = browser.apply(.enter)
        #expect(browser.current.name == "big")
        #expect(browser.currentPath == "/scan/big")
        _ = browser.apply(.left)
        #expect(browser.current.name == "root")
        let frame = browser.render(width: 100, height: 12, status: idle)
        #expect(selectedName(frame)?.hasSuffix("big/") == true)
    }

    @Test func ownFilesRowAndRootAreNotOpenable() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/")
        _ = browser.apply(.left)
        #expect(browser.trail.count == 1)
        _ = browser.apply(.down) // onto "[files]"
        _ = browser.apply(.enter)
        #expect(browser.trail.count == 1)
        #expect(browser.currentPath == "/")
    }

    @Test func quitKeysCloseEverythingElseDoesNot() {
        var browser = TUIBrowser(root: fixture(), rootPath: "/scan")
        #expect(browser.apply(.char("x")))
        #expect(browser.apply(.char("t")))
        #expect(browser.showTypes)
        #expect(browser.apply(.left))
        #expect(!browser.showTypes)
        #expect(!browser.apply(.char("q")))
        #expect(!browser.apply(.interrupt))
    }

    // MARK: Frames

    @Test func framesFitAnyTerminal() {
        let root = fixture()
        // Wide characters, a combining accent, an emoji: what a Character count
        // gets wrong and a terminal draws two cells wide (or none).
        let tricky = leaf("日本語のフォルダ-cafe\u{301}-📦-with-a-rather-long-name", in: root, bytes: 50)
        root.finishScan(children: root.children + [tricky], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        for width in [1, 12, 30, 49, 63, 80, 140] {
            for height in [1, 3, 4, 8, 30] {
                var browser = TUIBrowser(root: root, rootPath: "/a/rather/deep/path/to/the/scan/root")
                let frame = browser.render(width: width, height: height, status: idle)
                #expect(frame.count == height)
                for line in frame {
                    #expect(TextCell.width(plain(line)) <= width, "\(width)×\(height): \(plain(line))")
                }
            }
        }
    }

    @Test func fileNamesCannotDriveTheTerminal() {
        let root = fixture()
        let hostile = leaf("evil\u{1B}]0;pwned\u{07}\u{1B}[2J", in: root, bytes: 5000)
        root.finishScan(children: root.children + [hostile], filesLogical: 300, filesPhysical: 300, fileCount: 3)
        var browser = TUIBrowser(root: root, rootPath: "/scan")
        let frame = browser.render(width: 100, height: 12, status: idle)
        #expect(!frame.map(plain).joined().contains("\u{1B}"))
        #expect(!frame.joined().contains("\u{07}"))
    }

    @Test func liveFolderIsMarkedAndEmptyFolderSaysSo() {
        let root = FSNode(name: "root", parent: nil)
        let pending = FSNode(name: "pending", parent: root)
        root.appendChild(pending)
        var browser = TUIBrowser(root: root, rootPath: "/scan")
        let scanning = TUIBrowser.Status(scanning: true, elapsed: 0.5, files: 0, folders: 1, skipped: 0)
        let frame = browser.render(width: 100, height: 8, status: scanning).map(plain)
        #expect(frame[0].contains("scanning"))
        #expect(frame.contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("pending/ …") })
        _ = browser.apply(.enter)
        #expect(browser.render(width: 100, height: 8, status: scanning).map(plain).contains { $0.contains("(scanning…)") })
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

    @Test func barsAreExactWidth() {
        #expect(TextCell.bar(0, width: 10) == String(repeating: " ", count: 10))
        #expect(TextCell.bar(1, width: 10) == String(repeating: "█", count: 10))
        #expect(TextCell.bar(0.55, width: 10).hasPrefix("█████▌"))
        for step in 0...20 {
            #expect(TextCell.width(TextCell.bar(Double(step) / 20, width: 10)) == 10)
        }
    }
}
