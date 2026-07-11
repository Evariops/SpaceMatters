#!/usr/bin/env swift
// Generates the two committed DMG window assets, next to this file, from one
// set of geometry constants (the single source of truth, just below):
//
//   Packaging/dmg-background.png — the Finder window background, rendered
//     with AppKit (same no-design-asset approach as make-icon.sh).
//   Packaging/dmg.DS_Store — the Finder window layout (window bounds, icon
//     positions, background picture), written directly in the .DS_Store
//     binary format. Owning the format keeps the DMG build fully headless
//     and deterministic — scripting Finder instead was tried and it does not
//     persist what it is told (icon positions drifted +45 pt on macOS 26).
//
// Run ./Packaging/dmg-assets.swift after a look or geometry change, then
// commit the outputs. make-dmg.sh copies them verbatim into the image.
//
// .DS_Store format (reverse-engineered, stable since 10.4): a "Bud1" buddy
// allocator container holding a B-tree of (filename, field, value) records.
// The scope here is exactly the records a styled DMG needs, in a single
// leaf node. Layout notes: https://en.wikipedia.org/wiki/.DS_Store and
// Wim Lewis's format description.

import AppKit

// MARK: - Geometry & look (single source of truth)

let volumeName = "SpaceMatters"
let appName    = "SpaceMatters.app"

let windowOrigin = (x: 200, y: 120)  // where the window opens, on screen
let contentSize  = (w: 660, h: 420)  // content area == background size, in pt
let titleBarH    = 28                // Finder title bar above the content area
let appSlot      = (x: 165, y: 205)  // icon centres, Finder top-left coords
let appsSlot     = (x: 495, y: 205)
// Support files are invisible for most users; for viewers with hidden files
// shown, park them far outside the fixed window bounds instead of letting
// Finder auto-arrange them over the artwork. (They cannot be flag-hidden:
// makehybrid drops BSD flags, and "show hidden files" reveals dotfiles.)
let parkSlot     = (x: 1200, y: 205)
let iconSize     = 128
let textSize     = 13

// The app's dark panel look, shared with make-icon.sh.
let panelTop    = NSColor(srgbRed: 0x1B/255, green: 0x20/255, blue: 0x29/255, alpha: 1)
let panelBottom = NSColor(srgbRed: 0x10/255, green: 0x13/255, blue: 0x18/255, alpha: 1)
let accent      = NSColor(srgbRed: 0x4C/255, green: 0x8D/255, blue: 0xFF/255, alpha: 1)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("\(msg)\n".utf8))
    exit(1)
}

// MARK: - Background picture

func renderBackground() -> Data {
    let w = CGFloat(contentSize.w), h = CGFloat(contentSize.h)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("rep alloc failed") }
    // Point size half the pixel size -> 144 dpi, so Finder renders it Retina-sharp.
    // The bitmap context picks up that scale, so all drawing below is in points.
    rep.size = NSSize(width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Subtle vertical gradient around the app's dark panel colour.
    NSGradient(starting: panelTop, ending: panelBottom)?
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    func drawCentered(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x - size.width / 2, y: y - size.height / 2), withAttributes: attrs)
    }

    // Light chips under the Finder labels, which render black over a background
    // picture (regardless of the viewer's light/dark mode, and it is not
    // scriptable). Sized for the longest label ("SpaceMatters.app", shown when
    // "show all filename extensions" is enabled; most users see "SpaceMatters").
    let chip = NSColor(srgbRed: 0xF2/255, green: 0xF3/255, blue: 0xF6/255, alpha: 1)
    let labelFont = NSFont.systemFont(ofSize: CGFloat(textSize))
    let labelCentre = CGFloat(appSlot.y + iconSize / 2 + 17)  // measured: Finder's label centre
    for (label, x) in [(appName, CGFloat(appSlot.x)), ("Applications", CGFloat(appsSlot.x))] {
        let tw = label.size(withAttributes: [.font: labelFont]).width
        let rect = NSRect(x: x - tw / 2 - 14, y: h - labelCentre - 13, width: tw + 28, height: 26)
        chip.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13).fill()
    }

    drawCentered("SpaceMatters", font: .systemFont(ofSize: 26, weight: .semibold),
                 color: NSColor(white: 1, alpha: 0.96), x: w / 2, y: h - 64)
    // Kept well above the bottom edge: Finder's optional path bar (a global
    // viewer setting) covers the last ~24 pt of the background when enabled.
    drawCentered("Drag SpaceMatters onto Applications to install",
                 font: .systemFont(ofSize: 13), color: NSColor(white: 1, alpha: 0.45),
                 x: w / 2, y: 96)

    // Accent arrow midway between the two icon slots.
    let cfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        .applying(.init(paletteColors: [accent]))
    if let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let s = arrow.size
        arrow.draw(in: NSRect(x: w / 2 - s.width / 2, y: (h - CGFloat(appSlot.y)) - s.height / 2,
                              width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encode failed") }
    return png
}

// MARK: - .DS_Store: byte-level helpers

/// Big-endian byte buffer — everything in a .DS_Store is big-endian.
struct BE {
    private(set) var data = Data()
    mutating func u8(_ v: UInt8)     { data.append(v) }
    mutating func u16(_ v: UInt16)   { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32)   { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data)   { data.append(d) }
    mutating func ascii(_ s: String) { data.append(Data(s.utf8)) }
    mutating func utf16be(_ s: String) { for unit in s.utf16 { u16(unit) } }
    mutating func zeros(_ n: Int)    { data.append(Data(count: n)) }
    /// Pascal string in a fixed-width field: 1 length byte + zero padding.
    mutating func pascal(_ s: String, width: Int) {
        let b = Data(s.utf8)
        precondition(b.count < width, "'\(s)' overflows a \(width)-byte pascal field")
        u8(UInt8(b.count)); bytes(b); zeros(width - 1 - b.count)
    }
}

// MARK: - .DS_Store: background picture alias

/// Classic AliasRecord (version 2) pointing at the background picture.
/// Finder resolves it by volume name + path (reference DMGs in the wild ship
/// mount points and CNIDs from their build machine, and still work), so the
/// volume metadata below only needs to look plausible — the field values
/// mirror a known-good alias. The CNIDs are deliberately huge: never
/// allocated on a small volume, they force path-based resolution instead of
/// accidentally matching some other file's id.
func backgroundAliasRecord() -> Data {
    let folder = ".background", file = "background.png"
    let volDate: UInt32 = 3_785_000_000  // fixed plausible HFS date (2023)
    let parentCNID: UInt32 = 0x0FFF_FFF0
    let fileCNID: UInt32 = 0x0FFF_FFF1

    var tags = BE()
    func tag(_ id: UInt16, _ payload: Data) {
        tags.u16(id); tags.u16(UInt16(payload.count)); tags.bytes(payload)
        if payload.count % 2 != 0 { tags.u8(0) }  // tags are padded to even length
    }
    func counted(_ s: String) -> Data {           // UTF-16 payload: count + chars
        var b = BE(); b.u16(UInt16(s.utf16.count)); b.utf16be(s); return b.data
    }
    tag(0, Data(folder.utf8))                                  // parent folder name
    tag(2, Data("\(volumeName):\(folder):\(file)".utf8))       // carbon path
    tag(14, counted(file))                                     // unicode file name
    tag(15, counted(volumeName))                               // unicode volume name
    tag(18, Data("/\(folder)/\(file)".utf8))                   // posix path on the volume
    tag(19, Data("/Volumes/\(volumeName)".utf8))               // volume mount point
    tags.u16(0xFFFF); tags.u16(0)                              // end of tags

    var a = BE()
    a.u32(0)                            // user type
    a.u16(0)                            // record size — patched below
    a.u16(2)                            // alias format version
    a.u16(0)                            // target kind: file
    a.pascal(volumeName, width: 28)     // volume name
    a.u32(volDate)                      // volume creation date
    a.ascii("H+"); a.u16(5)             // filesystem type; disk type 5 = disk image
    a.u32(parentCNID)                   // parent directory CNID
    a.pascal(file, width: 64)           // target name
    a.u32(fileCNID)                     // target CNID
    a.u32(volDate)                      // target creation date
    a.u32(0); a.u32(0)                  // creator / type code
    a.u16(0xFFFF); a.u16(0xFFFF)        // alias-to-alias levels: -1 (unused)
    a.u32(0x0D02)                       // volume attributes (as real HFS+ images)
    a.u16(0)                            // volume filesystem id
    a.zeros(10)                         // reserved
    a.bytes(tags.data)

    var record = a.data
    record[4] = UInt8(record.count >> 8)  // patch the record size field
    record[5] = UInt8(record.count & 0xFF)
    return record
}

// MARK: - .DS_Store: the records

/// Binary plist with stable output: NSMutableDictionary keeps CF's non-seeded
/// key ordering, unlike a bridged Swift Dictionary (per-process hash seed).
func binaryPlist(_ build: (NSMutableDictionary) -> Void) -> Data {
    let dict = NSMutableDictionary()
    build(dict)
    return try! PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
}

/// 'Iloc': icon position — x, y (top-left coords) then a constant trailer.
func iloc(_ slot: (x: Int, y: Int)) -> Data {
    var b = BE()
    b.u32(UInt32(slot.x)); b.u32(UInt32(slot.y))
    b.bytes(Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00]))
    return b.data
}

/// One B-tree record: filename, field id, typed value.
enum Value { case blob(Data), long(UInt32) }
func record(_ name: String, _ id: String, _ value: Value) -> Data {
    var r = BE()
    r.u32(UInt32(name.utf16.count)); r.utf16be(name)
    r.ascii(id)
    switch value {
    case .long(let v): r.ascii("long"); r.u32(v)
    case .blob(let d): r.ascii("blob"); r.u32(UInt32(d.count)); r.bytes(d)
    }
    return r.data
}

func makeRecords() -> [Data] {
    // 'bwsp': window geometry and chrome. Bounds include the title bar, so the
    // background exactly fills the content area below it.
    let bwsp = binaryPlist { d in
        d["WindowBounds"] = "{{\(windowOrigin.x), \(windowOrigin.y)}, "
                          + "{\(contentSize.w), \(contentSize.h + titleBarH)}}"
        d["ShowStatusBar"] = false
        d["ShowPathbar"] = false
        d["ShowToolbar"] = false
        d["ShowTabView"] = false
        d["ShowSidebar"] = false
        d["ContainerShowSidebar"] = false
        d["PreviewPaneVisibility"] = false
        d["SidebarWidth"] = 180
    }

    // 'icvp': icon-view options — free arrangement and the background picture.
    // Key set mirrors known-good DMGs (colour keys are present even with a
    // picture background).
    let icvp = binaryPlist { d in
        d["viewOptionsVersion"] = 1
        d["backgroundType"] = 2  // 2 = background picture
        d["backgroundColorRed"] = 1.0
        d["backgroundColorGreen"] = 1.0
        d["backgroundColorBlue"] = 1.0
        d["backgroundImageAlias"] = backgroundAliasRecord()
        d["arrangeBy"] = "none"
        d["iconSize"] = Double(iconSize)
        d["textSize"] = Double(textSize)
        d["gridSpacing"] = 100.0
        d["gridOffsetX"] = 0.0
        d["gridOffsetY"] = 0.0
        d["labelOnBottom"] = true
        d["showIconPreview"] = false
        d["showItemInfo"] = false
        d["scrollPositionX"] = 0.0
        d["scrollPositionY"] = 0.0
    }

    // Sorted as the B-tree requires: case-insensitively by filename, then by
    // field id.
    return [
        record(".", "bwsp", .blob(bwsp)),
        record(".", "icvp", .blob(icvp)),
        record(".", "vSrn", .long(1)),  // view settings version
        record(".VolumeIcon.icns", "Iloc", .blob(iloc(parkSlot))),
        record(".background", "Iloc", .blob(iloc(parkSlot))),
        record("Applications", "Iloc", .blob(iloc(appsSlot))),
        record(appName, "Iloc", .blob(iloc(appSlot))),
    ]
}

// MARK: - .DS_Store: Bud1 container

/// Fixed buddy-allocator layout (all offsets relative to the 4-byte magic):
///   0x0000   32 B   file header
///   0x0020   32 B   block 1 — "DSDB" superblock
///   0x0800  2 KiB   block 0 — bookkeeping (addresses, TOC, free lists)
///   0x1000  4 KiB   block 2 — the single B-tree leaf node
/// The free lists hold the buddy decomposition of everything else.
func dsStoreFile() -> Data {
    let records = makeRecords()

    var node = BE()
    node.u32(0)  // 0 = leaf node
    node.u32(UInt32(records.count))
    records.forEach { node.bytes($0) }
    precondition(node.data.count <= 0x1000, "records overflow the single tree node")

    var superblock = BE()
    superblock.u32(2)                       // root node lives in block 2
    superblock.u32(0)                       // tree height above the leaves
    superblock.u32(UInt32(records.count))
    superblock.u32(1)                       // total node count
    superblock.u32(0x1000)                  // node page size

    var book = BE()
    book.u32(3); book.u32(0)                // 3 allocated blocks
    // Block addresses (offset | log2 size), padded to 256 entries.
    book.u32(0x800 | 11); book.u32(0x20 | 5); book.u32(0x1000 | 12)
    book.zeros((256 - 3) * 4)
    book.u32(1)                             // TOC: one directory
    book.u8(4); book.ascii("DSDB"); book.u32(1)
    // 32 free lists, one per power of two: [0x40, 0x800) split buddy-style,
    // then one free block of each size from 8 KiB up to 1 GiB.
    for k in 0..<32 {
        switch k {
        case 6...10, 13...30: book.u32(1); book.u32(UInt32(1) << k)
        default:              book.u32(0)
        }
    }

    var f = BE()
    f.u32(1); f.ascii("Bud1")
    f.u32(0x800); f.u32(0x800); f.u32(0x800)  // bookkeeping offset / size / offset
    f.zeros(16)                               // unused header tail
    f.bytes(superblock.data)                  // block 1 starts right at +0x20
    f.zeros(4 + 0x800 - f.data.count)
    f.bytes(book.data)
    f.zeros(4 + 0x1000 - f.data.count)
    f.bytes(node.data)
    f.zeros(4 + 0x2000 - f.data.count)        // fill block 2 to its full 4 KiB
    return f.data
}

// MARK: - Main

let packaging = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
try! renderBackground().write(to: packaging.appendingPathComponent("dmg-background.png"))
try! dsStoreFile().write(to: packaging.appendingPathComponent("dmg.DS_Store"))
print("wrote dmg-background.png and dmg.DS_Store in \(packaging.path)")
