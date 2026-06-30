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
    unowned(unsafe) let parent: FSNode?
    let isDirectory: Bool

    /// Subtree totals — sum of direct files of this node and all descendants.
    let aggLogical = Atomic<Int64>(0)
    let aggPhysical = Atomic<Int64>(0)
    let fileCount = Atomic<Int64>(0)

    /// This directory's own immediate files (set once, before `setChildren`).
    private(set) var directFilesLogical: Int64 = 0
    private(set) var directFilesPhysical: Int64 = 0
    private(set) var directFileCount: Int64 = 0

    /// Extension that accounts for the most bytes among this directory's direct
    /// files — used to colour the treemap by file type.
    private(set) var dominantExt: ExtKey = .none

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
    func updateDominantExt(_ ext: ExtKey) { dominantExt = ext }

    /// Detach a child (after it's been trashed/deleted on disk).
    func removeChild(_ child: FSNode) {
        gTreeLock.lock(); _children.removeAll { $0 === child }; gTreeLock.unlock()
    }

    /// Adjust this directory's own-file totals (after a file was removed).
    func adjustDirectFiles(logical: Int64, physical: Int64, count: Int64) {
        directFilesLogical = max(0, directFilesLogical + logical)
        directFilesPhysical = max(0, directFilesPhysical + physical)
        directFileCount = max(0, directFileCount + count)
    }

    /// Called once by the owning worker after a directory's entries are read.
    func finishScan(
        children: [FSNode],
        filesLogical: Int64,
        filesPhysical: Int64,
        fileCount: Int64,
        dominantExt: ExtKey = .none
    ) {
        directFilesLogical = filesLogical
        directFilesPhysical = filesPhysical
        directFileCount = fileCount
        self.dominantExt = dominantExt
        gTreeLock.lock()
        _children = children
        _scanned = true
        gTreeLock.unlock()
    }

    // MARK: Convenience

    @inline(__always)
    func size(_ metric: SizeMetric) -> Int64 {
        switch metric {
        case .logical: return aggLogical.load(ordering: .relaxed)
        case .physical: return aggPhysical.load(ordering: .relaxed)
        }
    }

    @inline(__always)
    func directFilesSize(_ metric: SizeMetric) -> Int64 {
        switch metric {
        case .logical: return directFilesLogical
        case .physical: return directFilesPhysical
        }
    }
}

extension FSNode: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension FSNode: Hashable {
    static func == (lhs: FSNode, rhs: FSNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Which size to report. Physical (on-disk allocated) matches "space used" the
/// way WinDirStats does; logical is the byte length of the content.
enum SizeMetric: String, CaseIterable, Identifiable {
    case physical
    case logical
    var id: String { rawValue }
    var label: String { self == .physical ? "On disk" : "Logical" }
}

/// A single global lock guards every node's children array. Writes happen once
/// per directory (cheap, brief); UI reads snapshot only the expanded/visible
/// nodes — so contention stays low even under a hot scan.
let gTreeLock = NSLock()
