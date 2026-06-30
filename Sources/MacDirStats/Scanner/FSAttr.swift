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
    static let cmnObjType: UInt32       = 0x0000_0008
    static let cmnError: UInt32         = 0x2000_0000

    // File attribute bits
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
    let logicalSize: Int64
    let physicalSize: Int64
}

/// Enumerate every direct child of an open directory file descriptor, invoking
/// `body` once per entry. Reuses `buffer` across calls to avoid per-directory
/// allocations. Returns the number of entries that reported an error (skipped).
@discardableResult
func enumerateDirectory(
    fd: Int32,
    buffer: UnsafeMutableRawPointer,
    bufferSize: Int,
    _ body: (BulkEntry) -> Void
) -> Int {
    var attrList = attrlist()
    attrList.bitmapcount = 5 // ATTR_BIT_MAP_COUNT
    attrList.commonattr = FSAttr.cmnReturnedAttrs | FSAttr.cmnName | FSAttr.cmnObjType | FSAttr.cmnError
    attrList.fileattr = FSAttr.fileTotalSize | FSAttr.fileAllocSize

    var errorCount = 0

    while true {
        let count = withUnsafeMutablePointer(to: &attrList) { alPtr in
            getattrlistbulk(fd, alPtr, buffer, bufferSize, 0)
        }
        if count <= 0 { break } // 0 == done, -1 == error (errno set)

        var entry = buffer
        for _ in 0..<count {
            let entryLength = entry.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            var off = 4

            // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
            let commonReturned = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            let fileReturned = entry.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self)
            off += 20

            var namePtr: UnsafeRawPointer? = nil
            var nameLen = 0
            if commonReturned & FSAttr.cmnName != 0 {
                let nameOffset = entry.loadUnaligned(fromByteOffset: off, as: Int32.self)
                let rawLen = entry.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
                let nameByteOffset = off + Int(nameOffset)
                namePtr = UnsafeRawPointer(entry.advanced(by: nameByteOffset))
                nameLen = Int(rawLen)
                if nameLen > 0 { nameLen -= 1 } // strip trailing NUL
                off += 8
            }

            var objType: UInt32 = 0
            if commonReturned & FSAttr.cmnObjType != 0 {
                objType = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
            }

            var entryError: UInt32 = 0
            if commonReturned & FSAttr.cmnError != 0 {
                entryError = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
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
                    logicalSize: logical,
                    physicalSize: physical
                ))
            }

            entry = entry.advanced(by: Int(entryLength))
        }
    }

    return errorCount
}
