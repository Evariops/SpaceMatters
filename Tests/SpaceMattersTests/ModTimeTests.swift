import Testing
import Foundation
@testable import SpaceMatters

/// SPEC-14 phase 1 — `ATTR_CMN_MODTIME` rides the bulk buffer the walk already
/// fills. The parse position is the exposure (get it wrong and every attribute
/// after it misaligns, which `ScannerGoldenTests` would catch as wrong sizes);
/// these check that the value itself is right and propagates as a max.
@Suite struct ModTimeTests {

    private func fixture(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mds-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ bytes: Int, to url: URL, modified: Date) throws {
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func scan(_ root: URL) -> FSNode {
        let node = FSNode(name: root.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(root: node, rootPath: root.path)
        scanner.start()
        while !scanner.isFinished { usleep(5_000) }
        return node
    }

    @Test func newestWriteMatchesTheFilesystem() throws {
        let root = try fixture("mtime")
        defer { try? FileManager.default.removeItem(at: root) }

        let old = Date(timeIntervalSince1970: 1_400_000_000)  // 2014
        let newest = Date(timeIntervalSince1970: 1_700_000_000) // 2023
        try write(1000, to: root.appendingPathComponent("old.bin"), modified: old)
        try write(1000, to: root.appendingPathComponent("newer.bin"), modified: newest)

        let node = scan(root)
        #expect(node.newestMTime.load(ordering: .relaxed) == Int64(newest.timeIntervalSince1970))
        // Sub-second precision is dropped on purpose — a whole `timespec` is read
        // from the buffer, only its seconds are kept.
        #expect(node.newestWrite == Date(timeIntervalSince1970: newest.timeIntervalSince1970.rounded(.down)))
    }

    @Test func newestWritePropagatesAsAMaxUpTheChain() throws {
        let root = try fixture("mtime-deep")
        defer { try? FileManager.default.removeItem(at: root) }

        let cold = root.appendingPathComponent("cold")
        let warm = root.appendingPathComponent("warm/inner")
        try FileManager.default.createDirectory(at: cold, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: warm, withIntermediateDirectories: true)

        let ancient = Date(timeIntervalSince1970: 1_200_000_000)  // 2008
        let recent = Date(timeIntervalSince1970: 1_750_000_000)   // 2025
        try write(500, to: cold.appendingPathComponent("a.bin"), modified: ancient)
        try write(500, to: warm.appendingPathComponent("b.bin"), modified: recent)

        let node = scan(root)
        // The root takes the max of both branches; each branch keeps its own.
        #expect(node.newestMTime.load(ordering: .relaxed) == Int64(recent.timeIntervalSince1970))
        let coldNode = try #require(node.children.first { $0.name == "cold" })
        #expect(coldNode.newestMTime.load(ordering: .relaxed) == Int64(ancient.timeIntervalSince1970))
        // `warm` holds no file of its own — it inherits from `inner`, which is
        // exactly what a max-propagated watermark is for.
        let warmNode = try #require(node.children.first { $0.name == "warm" })
        #expect(warmNode.directFileCount == 0)
        #expect(warmNode.newestMTime.load(ordering: .relaxed) == Int64(recent.timeIntervalSince1970))
    }

    @Test func directoryMTimesAreIgnored() throws {
        // Touching a directory (creating and deleting an entry) must not make a
        // subtree of ancient files look warm — otherwise nearly every folder does.
        let root = try fixture("mtime-dir")
        defer { try? FileManager.default.removeItem(at: root) }

        let ancient = Date(timeIntervalSince1970: 1_200_000_000)
        try write(500, to: root.appendingPathComponent("a.bin"), modified: ancient)
        let scratch = root.appendingPathComponent("scratch.tmp")
        try Data(count: 1).write(to: scratch)
        try FileManager.default.removeItem(at: scratch) // bumps the directory's own mtime to now

        let node = scan(root)
        #expect(node.newestMTime.load(ordering: .relaxed) == Int64(ancient.timeIntervalSince1970))
    }

    @Test func unknownTimestampsStayUnknown() {
        // A streamed VM/SSH scan carries no timestamps. `0` must read as "no
        // information", never as 1970 — the whole coldness feature inverts if it
        // reports "56 years" for a missing attribute.
        let node = FSNode(name: "streamed", parent: nil)
        node.finishScan(children: [], filesLogical: 100, filesPhysical: 100, fileCount: 1)
        #expect(node.newestWrite == nil)
        #expect(TreeQuery.ageInDays(of: node) == nil)
    }

    @Test func zeroingAggregatesClearsTheWatermark() {
        // SPEC-02 invalidate: a stale watermark would survive a re-scan of a
        // subtree that has since had its newest file deleted.
        let node = FSNode(name: "n", parent: nil)
        node.raiseNewestMTime(1_700_000_000)
        node.zeroAggregates()
        #expect(node.newestWrite == nil)
    }

    @Test func raiseNeverLowers() {
        let node = FSNode(name: "n", parent: nil)
        node.raiseNewestMTime(1_700_000_000)
        node.raiseNewestMTime(1_200_000_000)
        #expect(node.newestMTime.load(ordering: .relaxed) == 1_700_000_000)
    }
}
