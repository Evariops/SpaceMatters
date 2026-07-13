import Darwin

/// Low-level constants and a fast directory enumerator built on `getattrlistbulk(2)`.
///
/// `getattrlistbulk` is the fastest way to walk a directory on macOS: a single
/// syscall returns a packed buffer describing many entries at once (name, type,
/// logical size and on-disk allocated size), so we avoid the classic
/// `readdir` + `lstat` round-trip per file.
enum FSAttr {
    // Common attribute bits (sys/attr.h)
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let cmnName: UInt32          = 0x0000_0001
    static let cmnDevID: UInt32         = 0x0000_0002 // dev_t, exact mode (inode dedup key)
    static let cmnObjType: UInt32       = 0x0000_0008
    static let cmnFlags: UInt32         = 0x0004_0000 // BSD st_flags (u_int32) — UF_COMPRESSED lives here
    static let cmnFileID: UInt32        = 0x0200_0000 // inode number (u_int64), exact mode
    static let cmnError: UInt32         = 0x2000_0000

    // BSD file flags (sys/stat.h)
    /// File data is transparently compressed by the filesystem (AFSC/decmpfs).
    /// Distinguishes "smaller on disk because compressed" from "smaller on disk
    /// because sparse" — the two causes call for different user guidance.
    static let ufCompressed: UInt32     = 0x0000_0020

    // Directory attribute bits
    static let dirMountStatus: UInt32   = 0x0000_0004
    // ATTR_DIR_MOUNTSTATUS flags
    static let mntStatusMountPoint: UInt32 = 0x0000_0001

    // File attribute bits
    static let fileLinkCount: UInt32    = 0x0000_0001 // hardlink count (u_int32), exact mode
    static let fileTotalSize: UInt32    = 0x0000_0002 // logical size, all forks
    static let fileAllocSize: UInt32    = 0x0000_0004 // on-disk size, all forks

    // vnode object types (sys/vnode.h)
    static let vdir: UInt32 = 2
}

/// A single entry yielded by the bulk enumerator.
///
/// `name` points into the syscall buffer and is only valid for the duration of
/// the callback — copy out anything you need to keep.
struct BulkEntry {
    let name: UnsafeRawPointer
    let nameLength: Int
    let isDirectory: Bool
    /// True when this directory is the mount point of another filesystem — the
    /// scanner uses it to stay on one volume (`-xdev` semantics).
    let isMountPoint: Bool
    let logicalSize: Int64
    let physicalSize: Int64
    /// BSD `st_flags` of the entry (0 when the filesystem doesn't report them,
    /// e.g. some network mounts) — used to tell compressed apart from sparse.
    let flags: UInt32
    /// Inode number — only populated when the enumerator is `hardlinkAware`
    /// (exact counting mode); `0` otherwise.
    let fileID: UInt64
    /// Device id of the filesystem holding the entry — `0` unless
    /// `hardlinkAware`. Inode numbers are only unique per filesystem, so the
    /// dedup key must be `(deviceID, fileID)`: a multi-volume scan (or `/`,
    /// which spans the System and Data volumes) would otherwise collide.
    let deviceID: UInt32
    /// Hardlink count — `0` unless `hardlinkAware`. `> 1` marks a file whose
    /// blocks are shared by several directory entries (dedup candidate).
    let linkCount: UInt32

    /// Content stored compressed (APFS/HFS+ transparent compression): the
    /// apparent size exceeds the footprint because the data shrank.
    @inline(__always)
    var isCompressed: Bool { flags & FSAttr.ufCompressed != 0 }

    /// Holes: fewer blocks allocated than the content length (VM/container disk
    /// images, database preallocations…). Never true for block-padded regular
    /// files — padding makes the physical size *larger*, not smaller.
    @inline(__always)
    var isSparse: Bool { !isCompressed && physicalSize < logicalSize }

    /// Bytes of apparent size not backed by disk blocks (0 for ordinary files).
    @inline(__always)
    var apparentExcess: Int64 { max(0, logicalSize - physicalSize) }
}

/// Enumerate every direct child of an open directory file descriptor, invoking
/// `body` once per entry. Reuses `buffer` across calls to avoid per-directory
/// allocations. Returns the number of entries that reported an error (skipped).
@discardableResult
func enumerateDirectory(
    fd: Int32,
    buffer: UnsafeMutableRawPointer,
    bufferSize: Int,
    hardlinkAware: Bool = false,
    _ body: (BulkEntry) -> Void
) -> Int {
    var attrList = attrlist()
    attrList.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
    attrList.commonattr = FSAttr.cmnReturnedAttrs | FSAttr.cmnName | FSAttr.cmnObjType
        | FSAttr.cmnFlags | FSAttr.cmnError
    attrList.dirattr = FSAttr.dirMountStatus
    attrList.fileattr = FSAttr.fileTotalSize | FSAttr.fileAllocSize
    // Exact counting mode also needs the inode + link count to dedup hardlinks.
    // Requested only then, so the default (attribution) path packs an identical
    // buffer to before — the reads below are gated on the returned-attr masks.
    if hardlinkAware {
        attrList.commonattr |= FSAttr.cmnDevID | FSAttr.cmnFileID
        attrList.fileattr |= FSAttr.fileLinkCount
    }

    var errorCount = 0

    while true {
        let count = withUnsafeMutablePointer(to: &attrList) { alPtr in
            getattrlistbulk(fd, alPtr, buffer, bufferSize, 0)
        }
        if count == 0 { break }                    // no more entries
        if count < 0 { errorCount += 1; break }    // EACCES/EIO/volume gone: partial listing, not a clean end

        var entry = buffer
        for _ in 0..<count {
            let entryLength = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            var off = 4

            // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
            let commonReturned = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            let dirReturned = entry.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self)
            let fileReturned = entry.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self)
            off += 20

            // ATTR_CMN_ERROR is packed immediately after ATTR_CMN_RETURNED_ATTRS —
            // *before* the name — per getattrlistbulk(2), an explicit exception to
            // the usual "order follows bit value" rule. Reading it first keeps every
            // later offset aligned even for entries the kernel could not stat;
            // otherwise an error entry misaligns the name attr_ref and can read out
            // of bounds (worse under -Ounchecked).
            var entryError: UInt32 = 0
            if commonReturned & FSAttr.cmnError != 0 {
                entryError = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            var namePtr: UnsafeRawPointer? = nil
            var nameLen = 0
            if commonReturned & FSAttr.cmnName != 0 {
                let nameOffset = entry.loadUnaligned(fromByteOffset: off, as: Int32.self)
                let rawLen = entry.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                let nameByteOffset = off + Int(nameOffset)
                // Defensive: only trust the name if its bytes sit inside this entry.
                if nameOffset >= 0, rawLen > 0,
                   nameByteOffset + Int(rawLen) <= Int(entryLength) {
                    namePtr = UnsafeRawPointer(entry.advanced(by: nameByteOffset))
                    nameLen = Int(rawLen) - 1 // strip trailing NUL
                }
                off += 8
            }

            // ATTR_CMN_DEVID (0x02) packs between NAME (0x01) and OBJTYPE (0x08).
            var deviceID: UInt32 = 0
            if commonReturned & FSAttr.cmnDevID != 0 {
                deviceID = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            var objType: UInt32 = 0
            if commonReturned & FSAttr.cmnObjType != 0 {
                objType = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            // ATTR_CMN_FLAGS (0x00040000) packs after OBJTYPE (0x08), before
            // FILEID (0x02000000) — ascending-bit order. Gated on the returned
            // mask: a filesystem that can't report flags just yields 0.
            var flags: UInt32 = 0
            if commonReturned & FSAttr.cmnFlags != 0 {
                flags = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            // ATTR_CMN_FILEID (0x02000000) sorts after ATTR_CMN_OBJTYPE (0x08) in
            // the buffer's ascending-bit packing order. Present only in exact mode.
            var fileID: UInt64 = 0
            if commonReturned & FSAttr.cmnFileID != 0 {
                fileID = entry.loadUnaligned(fromByteOffset: off, as: UInt64.self)
                off += 8
            }

            // Directory attributes follow the common block. Only directories carry
            // ATTR_DIR_MOUNTSTATUS; for files the bit is simply absent.
            var isMountPoint = false
            if dirReturned & FSAttr.dirMountStatus != 0 {
                let mountStatus = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                isMountPoint = (mountStatus & FSAttr.mntStatusMountPoint) != 0
                off += 4
            }

            // File attributes, in ascending-bit order: LINKCOUNT (0x01) before
            // TOTALSIZE (0x02) before ALLOCSIZE (0x04). LINKCOUNT is exact-mode only.
            var linkCount: UInt32 = 0
            if fileReturned & FSAttr.fileLinkCount != 0 {
                linkCount = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            // File-size attributes are only present for non-directory objects.
            var logical: Int64 = 0
            var physical: Int64 = 0
            if fileReturned & FSAttr.fileTotalSize != 0 {
                logical = entry.loadUnaligned(fromByteOffset: off, as: Int64.self)
                off += 8
            }
            if fileReturned & FSAttr.fileAllocSize != 0 {
                physical = entry.loadUnaligned(fromByteOffset: off, as: Int64.self)
                off += 8
            }

            if entryError != 0 {
                errorCount += 1
            } else if let np = namePtr, nameLen > 0 {
                body(BulkEntry(
                    name: np,
                    nameLength: nameLen,
                    isDirectory: objType == FSAttr.vdir,
                    isMountPoint: isMountPoint,
                    logicalSize: logical,
                    physicalSize: physical,
                    flags: flags,
                    fileID: fileID,
                    deviceID: deviceID,
                    linkCount: linkCount
                ))
            }

            entry = entry.advanced(by: Int(entryLength))
        }
    }

    return errorCount
}
