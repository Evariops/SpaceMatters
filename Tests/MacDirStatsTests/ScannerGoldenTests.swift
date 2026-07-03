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

    /// `du -sklx`: count hard links per link, stay on one volume, report KiB.
    static func duKiB(_ path: String) throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sklx", path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let firstField = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "0"
        return Int(firstField.trimmingCharacters(in: .whitespaces)) ?? -1
    }
}
