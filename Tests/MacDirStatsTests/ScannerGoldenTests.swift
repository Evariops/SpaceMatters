import Testing
import Foundation
@testable import MacDirStats

/// The golden correctness test: a controlled fixture scanned by `DirectoryScanner`
/// must agree with `du` to the kilobyte. This is what would catch a regression in
/// the `getattrlistbulk` offset arithmetic (A2) or the size propagation.
@Suite struct ScannerGoldenTests {

    @Test func matchesDuOnVariedFixture() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sub1 = root.appendingPathComponent("sub1")
        try fm.createDirectory(at: sub1, withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: sub1.appendingPathComponent("a.bin"))
        try Data(count: 3_000).write(to: sub1.appendingPathComponent("b.dat"))
        try Data("hi".utf8).write(to: root.appendingPathComponent("c.txt"))
        // A name containing a newline: the local scanner must handle it (and so
        // must `du`), so the totals still line up.
        try Data(count: 100).write(to: root.appendingPathComponent("wei\nrd.txt"))
        // A hard-link pair — counted once per link, like `du -l`.
        let orig = sub1.appendingPathComponent("orig.bin")
        try Data(count: 50_000).write(to: orig)
        try fm.linkItem(at: orig, to: sub1.appendingPathComponent("hard.link"))

        let node = FSNode(name: root.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(root: node, rootPath: root.path)
        scanner.start()
        while !scanner.isFinished { usleep(5_000) }

        #expect(scanner.scanErrorCount == 0)
        // 6 files: a.bin, b.dat, c.txt, wei\nrd.txt, orig.bin, hard.link
        #expect(node.fileCount.load(ordering: .relaxed) == 6)

        let ourKiB = Int((node.aggPhysical.load(ordering: .relaxed) + 1023) / 1024)
        let duKiB = try Self.duKiB(root.path)
        #expect(abs(ourKiB - duKiB) <= 1, "scan \(ourKiB) KiB vs du -sklx \(duKiB) KiB")
    }

    /// A3: exact mode dedups hardlinks (matches `du -skx`); attribution counts
    /// every link (`du -sklx`). This also validates the exact-mode bulk-buffer
    /// parsing — a bad FILEID/LINKCOUNT offset would break the dedup and fail here.
    @Test func exactModeDedupsHardlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-hl-\(UUID().uuidString)")
        let d1 = root.appendingPathComponent("d1")
        let d2 = root.appendingPathComponent("d2")
        try fm.createDirectory(at: d1, withIntermediateDirectories: true)
        try fm.createDirectory(at: d2, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // One 200 KB payload hardlinked into three places, plus an unshared file.
        let payload = d1.appendingPathComponent("payload.bin")
        try Data(count: 200_000).write(to: payload)
        try fm.linkItem(at: payload, to: d1.appendingPathComponent("link2.bin"))
        try fm.linkItem(at: payload, to: d2.appendingPathComponent("link3.bin"))
        try Data(count: 40_000).write(to: root.appendingPathComponent("solo.dat"))

        func scanTotal(exact: Bool) -> Int64 {
            let node = FSNode(name: root.lastPathComponent, parent: nil)
            let s = DirectoryScanner(root: node, seeds: [.init(path: root.path, node: node)], exact: exact)
            s.start(); s.waitUntilFinished()
            return node.aggPhysical.load(ordering: .relaxed)
        }

        let attribution = scanTotal(exact: false)
        let exact = scanTotal(exact: true)

        // Attribution counts all 3 links (~3 payloads + solo); exact counts the
        // shared blocks once (~1 payload + solo) — so it must be strictly smaller.
        #expect(exact < attribution)
        #expect(attribution - exact > 300_000) // ~2 extra payload copies elided

        // Cross-check the semantics against du itself.
        let exactKiB = Int((exact + 1023) / 1024)
        let attrKiB = Int((attribution + 1023) / 1024)
        #expect(abs(exactKiB - (try Self.duKiB(root.path, perLink: false))) <= 1,
                "exact \(exactKiB) KiB vs du -skx")
        #expect(abs(attrKiB - (try Self.duKiB(root.path, perLink: true))) <= 1,
                "attribution \(attrKiB) KiB vs du -sklx")
    }

    /// `du -sk[l]x`: with `-l` count hard links per link (attribution), without it
    /// dedup them (exact). Stay on one volume, report KiB.
    static func duKiB(_ path: String, perLink: Bool = true) throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = [perLink ? "-sklx" : "-skx", path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let firstField = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "0"
        return Int(firstField.trimmingCharacters(in: .whitespaces)) ?? -1
    }
}
