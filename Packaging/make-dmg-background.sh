#!/bin/bash
# Generate Packaging/dmg-background.png, the Finder window background used by
# make-dmg.sh. No design asset needed: renders the app's dark panel look with a
# title, an accent arrow between the two icon slots and an install hint, via
# AppKit (same approach as make-icon.sh). Re-run after a look change.
#
# Geometry contract with make-dmg.sh: 660x420 pt window, icons centred at
# (165, 205) and (495, 205) in Finder's top-left coordinates.
#
# Finder always draws icon labels in black when the window has a background
# picture (regardless of the viewer's light/dark mode, and it is not
# scriptable), so the background carries a light chip under each label slot.
set -euo pipefail
cd "$(dirname "$0")/.."

swift - Packaging/dmg-background.png <<'SWIFT'
import AppKit

let out = CommandLine.arguments[1]
let w: CGFloat = 660, h: CGFloat = 420
let scale: CGFloat = 2

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { FileHandle.standardError.write(Data("rep alloc failed\n".utf8)); exit(1) }
// Point size half the pixel size -> 144 dpi, so Finder renders it Retina-sharp.
// The bitmap context picks up that scale, so all drawing below is in points.
rep.size = NSSize(width: w, height: h)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Subtle vertical gradient around the app's dark panel colour (#161A21).
let top = NSColor(srgbRed: 0x1B/255, green: 0x20/255, blue: 0x29/255, alpha: 1)
let bottom = NSColor(srgbRed: 0x10/255, green: 0x13/255, blue: 0x18/255, alpha: 1)
NSGradient(starting: top, ending: bottom)?
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

let accent = NSColor(srgbRed: 0x4C/255, green: 0x8D/255, blue: 0xFF/255, alpha: 1)

func drawCentered(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: x - size.width / 2, y: y - size.height / 2), withAttributes: attrs)
}

// Light chips under the Finder labels, which render black over a background
// picture. Label centre sits ~284 pt from the top (icon bottom 269 + ~15).
// Sized for the longest label ("SpaceMatters.app", shown when the viewer has
// "show all filename extensions" enabled; most users see "SpaceMatters").
let chip = NSColor(srgbRed: 0xF2/255, green: 0xF3/255, blue: 0xF6/255, alpha: 1)
let labelFont = NSFont.systemFont(ofSize: 13)
for (label, x) in [("SpaceMatters.app", CGFloat(165)), ("Applications", CGFloat(495))] {
    let tw = label.size(withAttributes: [.font: labelFont]).width
    let rect = NSRect(x: x - tw / 2 - 14, y: h - 284 - 13, width: tw + 28, height: 26)
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

// Accent arrow midway between the icon slots (icon centres are 205 pt from the top).
let cfg = NSImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
    .applying(.init(paletteColors: [accent]))
if let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = arrow.size
    arrow.draw(in: NSRect(x: w / 2 - s.width / 2, y: (h - 205) - s.height / 2,
                          width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
SWIFT

echo "wrote Packaging/dmg-background.png"
