import Foundation
import Synchronization

/// One **directory** in the scanned tree.
///
/// Memory strategy: we keep a node per directory only. Files are *not* stored as
/// individual objects — instead each directory keeps the aggregate of its own
/// direct files (`directFiles*`). Since most filesystem objects are files, this
/// collapses the object count from "every file" down to "every directory",
/// which is the single biggest RAM win.
///
/// Live sizes use lock-free atomics so worker threads can keep adding while the
/// UI reads slightly-stale-but-consistent totals at display refresh rate. Size
/// is propagated to ancestors as each directory is scanned, so the tree fills in
/// "au fil de l'eau".
final class FSNode {
    let name: String
    // `unowned` (not `unowned(unsafe)`): the tree is retained top-down via
    // `_children`, so a surviving descendant whose ancestor was detached would
    // otherwise dangle. The liveness check costs nothing next to the syscalls and
    // turns any such bug into a diagnosable trap instead of silent corruption.
    unowned let parent: FSNode?
    let isDirectory: Bool

    /// Subtree totals — sum of direct files of this node and all descendants.
    let aggLogical = Atomic<Int64>(0)
    let aggPhysical = Atomic<Int64>(0)
    let fileCount = Atomic<Int64>(0)
    /// Classified apparent-vs-on-disk gap for the subtree: bytes of content
    /// length not backed by blocks in sparse files, and same for compressed
    /// files. Explains *why* `aggLogical` dwarfs `aggPhysical` where it does —
    /// sizes are always displayed on-disk; the gap surfaces as an annotation.
    let aggSparseExcess = Atomic<Int64>(0)
    let aggCompressedExcess = Atomic<Int64>(0)

    /// This directory's own immediate files. Atomic so the UI can read live
    /// totals at refresh rate while a worker is still filling them in — a node is
    /// published into its parent's `_children` before its own fields are set.
    private let _directFilesLogical = Atomic<Int64>(0)
    private let _directFilesPhysical = Atomic<Int64>(0)
    private let _directFileCount = Atomic<Int64>(0)
    private let _directSparseExcess = Atomic<Int64>(0)
    private let _directCompressedExcess = Atomic<Int64>(0)

    var directFilesLogical: Int64 { _directFilesLogical.load(ordering: .relaxed) }
    var directFilesPhysical: Int64 { _directFilesPhysical.load(ordering: .relaxed) }
    var directFileCount: Int64 { _directFileCount.load(ordering: .relaxed) }
    var directSparseExcess: Int64 { _directSparseExcess.load(ordering: .relaxed) }
    var directCompressedExcess: Int64 { _directCompressedExcess.load(ordering: .relaxed) }

    /// Extension that accounts for the most bytes among this directory's direct
    /// files — used to colour the treemap by file type. Guarded by `gTreeLock`:
    /// it's a 16-byte value a worker writes and the UI reads, so a plain field
    /// could tear (wrong tile colour).
    private var _dominantExt: ExtKey = .none
    var dominantExt: ExtKey {
        gTreeLock.lock(); defer { gTreeLock.unlock() }
        return _dominantExt
    }

    private var _children: [FSNode] = []
    private var _scanned = false

    init(name: String, parent: FSNode?, isDirectory: Bool = true) {
        self.name = name
        self.parent = parent
        self.isDirectory = isDirectory
    }

    // MARK: Child access (guarded — written by scanner, read by UI)

    /// Snapshot of child directories. Returns the COW buffer under lock so the
    /// reader holds a stable retain even if the worker replaces it later.
    var children: [FSNode] {
        gTreeLock.lock(); defer { gTreeLock.unlock() }
        return _children
    }

    var isScanned: Bool {
        gTreeLock.lock(); defer { gTreeLock.unlock() }
        return _scanned
    }

    var childCount: Int {
        gTreeLock.lock(); defer { gTreeLock.unlock() }
        return _children.count
    }

    /// Append a child discovered during an incremental (streamed) scan.
    func appendChild(_ child: FSNode) {
        gTreeLock.lock(); _children.append(child); _scanned = true; gTreeLock.unlock()
    }

    /// Set the dominant file type (used by streamed scans, which compute it live).
    func updateDominantExt(_ ext: ExtKey) {
        gTreeLock.lock(); _dominantExt = ext; gTreeLock.unlock()
    }

    /// Detach a child (after it's been trashed/deleted on disk).
    func removeChild(_ child: FSNode) {
        gTreeLock.lock(); _children.removeAll { $0 === child }; gTreeLock.unlock()
    }

    /// Adjust this directory's own-file totals (after a file was removed). Single
    /// writer (MainActor post-scan, or the streamed reader thread), so a plain
    /// load/store on the atomics is race-free against the UI's atomic reads.
    func adjustDirectFiles(logical: Int64, physical: Int64, count: Int64,
                           sparseExcess: Int64 = 0, compressedExcess: Int64 = 0) {
        _directFilesLogical.store(max(0, directFilesLogical + logical), ordering: .relaxed)
        _directFilesPhysical.store(max(0, directFilesPhysical + physical), ordering: .relaxed)
        _directFileCount.store(max(0, directFileCount + count), ordering: .relaxed)
        _directSparseExcess.store(max(0, directSparseExcess + sparseExcess), ordering: .relaxed)
        _directCompressedExcess.store(max(0, directCompressedExcess + compressedExcess), ordering: .relaxed)
    }

    /// Zero this node's subtree aggregates ahead of an in-place re-scan (SPEC-02
    /// `invalidate`): the re-scan re-propagates fresh direct-file totals into it.
    func zeroAggregates() {
        aggLogical.store(0, ordering: .relaxed)
        aggPhysical.store(0, ordering: .relaxed)
        fileCount.store(0, ordering: .relaxed)
        aggSparseExcess.store(0, ordering: .relaxed)
        aggCompressedExcess.store(0, ordering: .relaxed)
    }

    /// Called once by the owning worker after a directory's entries are read.
    func finishScan(
        children: [FSNode],
        filesLogical: Int64,
        filesPhysical: Int64,
        fileCount: Int64,
        dominantExt: ExtKey = .none,
        sparseExcess: Int64 = 0,
        compressedExcess: Int64 = 0
    ) {
        _directFilesLogical.store(filesLogical, ordering: .relaxed)
        _directFilesPhysical.store(filesPhysical, ordering: .relaxed)
        _directFileCount.store(fileCount, ordering: .relaxed)
        _directSparseExcess.store(sparseExcess, ordering: .relaxed)
        _directCompressedExcess.store(compressedExcess, ordering: .relaxed)
        gTreeLock.lock()
        _dominantExt = dominantExt
        _children = children
        _scanned = true
        gTreeLock.unlock()
    }

    // MARK: Convenience

    /// The size this app renders everywhere: allocated blocks — what deleting
    /// frees, what fills the disk. (The apparent size is annotation-only.)
    @inline(__always)
    var sizeOnDisk: Int64 { aggPhysical.load(ordering: .relaxed) }

    /// Content length (`st_size` sum) — what a copy, upload or non-sparse-aware
    /// backup of this subtree would write. Shown only where it notably diverges.
    @inline(__always)
    var sizeApparent: Int64 { aggLogical.load(ordering: .relaxed) }

    /// Non-nil when this subtree's apparent size notably exceeds its footprint
    /// (sparse or compressed content) — drives the divergence badge.
    var divergence: SizeDivergence? {
        SizeDivergence.notable(
            onDisk: sizeOnDisk, apparent: sizeApparent,
            sparseExcess: aggSparseExcess.load(ordering: .relaxed),
            compressedExcess: aggCompressedExcess.load(ordering: .relaxed))
    }
}

extension FSNode: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FSNode: Hashable {
    static func == (lhs: FSNode, rhs: FSNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The gap between an item's *apparent* size (content length — the Finder's
/// "Size", what a copy/upload/backup writes) and its *on-disk* footprint
/// (allocated blocks — what deleting frees).
///
/// The two split when files are sparse (VM/container disk images: huge declared
/// length, few real blocks) or transparently compressed. A 512 GiB sparse image
/// occupying 75 MiB is correct data that *reads* as a bug — so the app renders
/// on-disk sizes everywhere and explains the gap in place, where it's notable,
/// instead of offering a global "Logical" mode that re-weighted the whole map
/// with un-actionable numbers.
struct SizeDivergence: Equatable {
    let onDisk: Int64
    let apparent: Int64
    /// Apparent bytes not backed by blocks, split by cause. May not sum to the
    /// whole gap: streamed scans can't classify, and block padding offsets it.
    let sparseExcess: Int64
    let compressedExcess: Int64

    /// Badge threshold: the apparent size must dwarf the footprint enough to
    /// mislead (≥ 1.5× and ≥ 8 MiB over). Block-padding noise never qualifies —
    /// padding makes on-disk the *larger* of the two.
    static let minDelta: Int64 = 8 << 20

    static func notable(onDisk: Int64, apparent: Int64,
                        sparseExcess: Int64, compressedExcess: Int64) -> SizeDivergence? {
        guard apparent - onDisk >= minDelta, apparent >= onDisk + onDisk / 2 else { return nil }
        return SizeDivergence(onDisk: onDisk, apparent: apparent,
                              sparseExcess: sparseExcess, compressedExcess: compressedExcess)
    }

    /// Dominant cause(s) — one is named when it explains ≥ 25% of the gap.
    private var causes: (sparse: Bool, compressed: Bool) {
        let gap = max(1, apparent - onDisk)
        return (sparseExcess * 4 >= gap, compressedExcess * 4 >= gap)
    }

    var label: String {
        switch causes {
        case (true, true): return "sparse + compressed"
        case (true, false): return "sparse"
        case (false, true): return "compressed"
        case (false, false): return "sparse or compressed"
        }
    }

    /// Tooltip text: both figures plus what the gap means for the user.
    var summary: String {
        var s = "\(Format.bytes(onDisk)) on disk · \(Format.bytes(apparent)) apparent."
        switch causes {
        case (true, false), (true, true):
            s += "\nSparse content (disk image, preallocated file): space is allocated on demand. A copy, upload or non-sparse backup can balloon to the apparent size."
        case (false, true):
            s += "\nCompressed by the filesystem: the content is larger than the space it occupies."
        case (false, false):
            s += "\nThe content is larger than the space it occupies (sparse or compressed files)."
        }
        return s
    }
}

/// How shared storage is counted. **Attribution** (default) blames every hardlink
/// for the full bytes ("who is responsible for this space") — clones count full.
/// **Exact** dedups hardlinks so the total matches `du`/`df` ("what's actually on
/// disk"). Because dedup happens while scanning (files aren't kept in RAM),
/// switching modes re-scans.
enum CountingMode: String, CaseIterable, Identifiable {
    case attribution
    case exact
    var id: String { rawValue }
    var label: String { self == .attribution ? "Attribution" : "Exact" }
}

/// A single global lock guards every node's children array. Writes happen once
/// per directory (cheap, brief); UI reads snapshot only the expanded/visible
/// nodes — so contention stays low even under a hot scan.
let gTreeLock = NSLock()
