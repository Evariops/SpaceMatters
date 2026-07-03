#!/bin/bash
# Generate Resources/AppIcon.icns from the app's pie-chart mark (J1.2). No design
# asset needed: renders the `chart.pie.fill` SF Symbol on the app's dark panel,
# then builds every iconset size with sips + iconutil. Re-run after a look change.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master.png"

swift - "$MASTER" <<'SWIFT'
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Rounded-rect background in the app's dark panel colour.
let inset = size * 0.08
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
NSColor(srgbRed: 0x16/255, green: 0x1A/255, blue: 0x21/255, alpha: 1).setFill()
bg.fill()

// The pie mark, tinted the app accent, centred.
let accent = NSColor(srgbRed: 0x4C/255, green: 0x8D/255, blue: 0xFF/255, alpha: 1)
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
    .applying(.init(paletteColors: [accent]))
if let sym = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: out))
SWIFT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s"          "$MASTER" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
