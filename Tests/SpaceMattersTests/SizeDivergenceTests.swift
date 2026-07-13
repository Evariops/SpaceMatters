import Testing
import Foundation
@testable import SpaceMatters

/// SPEC bug-fix: "Logical" as a global mode was removed — the apparent size now
/// surfaces as a per-item annotation (`SizeDivergence`) classified sparse vs
/// compressed. These tests pin the threshold policy, the scanner's per-file
/// classification (ATTR_CMN_FLAGS / UF_COMPRESSED), and the aggregate propagation.
@Suite struct SizeDivergenceTests {

    // MARK: Threshold policy (pure)

    @Test func notableRequiresBothRatioAndDelta() {
        // Big ratio, tiny delta (a 100 B file "10× sparse"): noise, no badge.
        #expect(SizeDivergence.notable(onDisk: 100, apparent: 1_000, sparseExcess: 900, compressedExcess: 0) == nil)
        // Big delta, small ratio (a 100 GB folder 9 GB apparent over): 1.09× — no badge.
        let gb: Int64 = 1 << 30
        #expect(SizeDivergence.notable(onDisk: 100 * gb, apparent: 109 * gb, sparseExcess: 9 * gb, compressedExcess: 0) == nil)
        // Both met: badge.
        #expect(SizeDivergence.notable(onDisk: gb, apparent: 2 * gb, sparseExcess: gb, compressedExcess: 0) != nil)
        // The 512 GiB sparse snapshot occupying 75 MiB — the bug that started this.
        let d = SizeDivergence.notable(onDisk: 75 << 20, apparent: 512 * gb, sparseExcess: 512 * gb - (75 << 20), compressedExcess: 0)
        #expect(d?.label == "sparse")
        // Fully sparse (0 blocks allocated) must qualify too.
        #expect(SizeDivergence.notable(onDisk: 0, apparent: 100 << 20, sparseExcess: 100 << 20, compressedExcess: 0) != nil)
        // Padding direction (on-disk > apparent) never qualifies.
        #expect(SizeDivergence.notable(onDisk: 2 * gb, apparent: gb, sparseExcess: 0, compressedExcess: 0) == nil)
    }

    @Test func labelFollowsDominantCause() {
        let gb: Int64 = 1 << 30
        let sparse = SizeDivergence.notable(onDisk: gb, apparent: 3 * gb, sparseExcess: 2 * gb, compressedExcess: 0)
        #expect(sparse?.label == "sparse")
        let compressed = SizeDivergence.notable(onDisk: gb, apparent: 3 * gb, sparseExcess: 0, compressedExcess: 2 * gb)
        #expect(compressed?.label == "compressed")
        let both = SizeDivergence.notable(onDisk: gb, apparent: 3 * gb, sparseExcess: gb, compressedExcess: gb)
        #expect(both?.label == "sparse + compressed")
        // Unclassified gap (streamed scans, hardlink dedup): honest generic label.
        let unknown = SizeDivergence.notable(onDisk: gb, apparent: 3 * gb, sparseExcess: 0, compressedExcess: 0)
        #expect(unknown?.label == "sparse or compressed")
    }

    // MARK: Scanner classification (integration, real APFS)

    /// A 100 MB `ftruncate` hole must be booked as sparse excess and propagate
    /// to every ancestor — the com.apple.container snapshot case in miniature.
    @Test func sparseFileClassifiedAndPropagated() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-sparse-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("images")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sparsePath = sub.appendingPathComponent("disk.img").path
        let fd = open(sparsePath, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        let declared: Int64 = 100 << 20 // 100 MiB declared, ~0 allocated
        #expect(ftruncate(fd, declared) == 0)
        close(fd)
        try Data(count: 50_000).write(to: sub.appendingPathComponent("real.bin"))

        let node = FSNode(name: root.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(root: node, rootPath: root.path)
        scanner.start()
        while !scanner.isFinished { usleep(5_000) }

        let sparseExcess = node.aggSparseExcess.load(ordering: .relaxed)
        #expect(sparseExcess >= declared - (1 << 20), "hole must dominate the excess (got \(sparseExcess))")
        #expect(node.aggCompressedExcess.load(ordering: .relaxed) == 0)

        // The badge fires at the root and names the right cause.
        let d = try #require(node.divergence)
        #expect(d.label == "sparse")
        #expect(d.apparent >= declared)

        // …and on the subdirectory holding the image (propagation, not just root).
        let images = try #require(node.children.first { $0.name == "images" })
        #expect(images.aggSparseExcess.load(ordering: .relaxed) == sparseExcess)
    }

    /// An APFS-compressed file (`ditto --hfsCompression`) must be booked as
    /// compressed — not sparse — excess.
    @Test func compressedFileClassified() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-comp-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Highly compressible payload, then ditto re-writes it compressed.
        let plain = root.appendingPathComponent("plain.txt")
        try Data(repeating: 0x41, count: 4 << 20).write(to: plain)
        let squeezed = root.appendingPathComponent("squeezed.txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["--hfsCompression", plain.path, squeezed.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        try fm.removeItem(at: plain)

        // Precondition: the filesystem really did compress (UF_COMPRESSED set).
        var st = stat()
        #expect(stat(squeezed.path, &st) == 0)
        try #require(st.st_flags & UInt32(UF_COMPRESSED) != 0, "ditto did not compress — fixture invalid")

        let node = FSNode(name: root.lastPathComponent, parent: nil)
        let scanner = DirectoryScanner(root: node, rootPath: root.path)
        scanner.start()
        while !scanner.isFinished { usleep(5_000) }

        #expect(node.aggCompressedExcess.load(ordering: .relaxed) > 0)
        #expect(node.aggSparseExcess.load(ordering: .relaxed) == 0,
                "a compressed file must never be double-booked as sparse")
        #expect(node.aggLogical.load(ordering: .relaxed) >= 4 << 20)
    }

    /// Exact mode books a hardlinked sparse file's excess once, like its bytes —
    /// attribution mode charges every link.
    @Test func exactModeDedupsSparseExcess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mds-sphl-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let imgPath = root.appendingPathComponent("disk.img").path
        let fd = open(imgPath, O_CREAT | O_WRONLY, 0o644)
        #expect(fd >= 0)
        let declared: Int64 = 20 << 20
        #expect(ftruncate(fd, declared) == 0)
        close(fd)
        try fm.linkItem(atPath: imgPath, toPath: root.appendingPathComponent("disk.link").path)

        func scan(exact: Bool) -> Int64 {
            let node = FSNode(name: "r", parent: nil)
            let scanner = DirectoryScanner(root: node, seeds: [.init(path: root.path, node: node)], exact: exact)
            scanner.start()
            while !scanner.isFinished { usleep(5_000) }
            return node.aggSparseExcess.load(ordering: .relaxed)
        }

        let attributed = scan(exact: false)
        let exact = scan(exact: true)
        #expect(attributed >= 2 * (declared - (1 << 20)), "attribution charges both links")
        #expect(exact >= declared - (1 << 20) && exact < declared + (1 << 20), "exact counts the inode once")
    }
}
