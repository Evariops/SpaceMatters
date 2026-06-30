import Foundation

/// A file-extension key that holds up to 16 lowercased ASCII bytes inline in two
/// `UInt64`s — so we can tally per-extension statistics for millions of files
/// without allocating a `String` per file. Strings are only materialised when
/// the (small) table is shown in the UI.
struct ExtKey: Hashable {
    let lo: UInt64
    let hi: UInt64

    static let none = ExtKey(lo: 0, hi: 0)            // no extension
    static let overflow = ExtKey(lo: .max, hi: .max)  // extension longer than 16 bytes

    /// Derive the extension key from a raw file name (bytes valid for the call only).
    @inline(__always)
    init(name ptr: UnsafeRawPointer, length: Int) {
        let bytes = ptr.assumingMemoryBound(to: UInt8.self)
        var dot = -1
        var i = length - 1
        while i >= 0 {
            let c = bytes[i]
            if c == 0x2F { break }      // '/' — defensive, names shouldn't contain it
            if c == 0x2E { dot = i; break } // '.'
            i -= 1
        }

        // No dot, leading dot (dotfile), or trailing dot → treat as "no extension".
        guard dot > 0, dot < length - 1 else {
            self = .none
            return
        }

        let start = dot + 1
        let extLen = length - start
        guard extLen <= 16 else {
            self = .overflow
            return
        }

        var packed: (UInt64, UInt64) = (0, 0)
        withUnsafeMutableBytes(of: &packed) { raw in
            for j in 0..<extLen {
                var c = bytes[start + j]
                if c >= 0x41 && c <= 0x5A { c += 32 } // ASCII upper → lower
                raw[j] = c
            }
        }
        self.lo = packed.0
        self.hi = packed.1
    }

    private init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
    }

    /// Derive the extension key from a file name string (for streamed scans).
    init(fileName: String) {
        if fileName.isEmpty { self = .none; return }
        let bytes = Array(fileName.utf8)
        self = bytes.withUnsafeBytes { raw in
            ExtKey(name: raw.baseAddress!, length: raw.count)
        }
    }

    /// Human-readable name for display (e.g. ".png", "[no extension]").
    var displayName: String {
        if self == .none { return "[no extension]" }
        if self == .overflow { return "[long extension]" }
        var packed = (lo, hi)
        return withUnsafeBytes(of: &packed) { raw -> String in
            var n = 0
            while n < 16, raw[n] != 0 { n += 1 }
            let chars = UnsafeRawBufferPointer(rebasing: raw[0..<n])
            return "." + String(decoding: chars, as: UTF8.self)
        }
    }
}

/// Aggregated statistics for one extension.
struct ExtStat {
    var logical: Int64 = 0
    var physical: Int64 = 0
    var count: Int64 = 0

    @inline(__always)
    mutating func add(logical l: Int64, physical p: Int64) {
        logical += l
        physical += p
        count += 1
    }

    @inline(__always)
    mutating func merge(_ other: ExtStat) {
        logical += other.logical
        physical += other.physical
        count += other.count
    }
}
