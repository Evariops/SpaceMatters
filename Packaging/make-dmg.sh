#!/bin/bash
# Package an .app bundle into a styled, compressed DMG: custom background with
# a drag-to-Applications hint (Packaging/dmg-background.png, see
# make-dmg-background.sh), positioned icons and a custom volume icon. The
# layout is written into the image's .DS_Store by scripting Finder on a
# read-write image, which is then compressed to UDZO.
# Shared by release.sh (local) and .github/workflows/release.yml (CI).
# Usage: Packaging/make-dmg.sh <App.app> <output.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <App.app> <output.dmg>}"
DMG="${2:?usage: make-dmg.sh <App.app> <output.dmg>}"
APP_NAME="$(basename "$APP")"
VOLNAME="$(basename "$APP" .app)"
PACKAGING="$(cd "$(dirname "$0")" && pwd)"

# The window background is stored in .DS_Store as an alias that embeds the
# volume name: building while another "$VOLNAME" volume is mounted would bake
# in "$VOLNAME 1" and the background would not show for end users.
if [ -d "/Volumes/$VOLNAME" ]; then
    echo "error: a volume named '$VOLNAME' is already mounted — eject it first" >&2
    exit 1
fi

rm -f "$DMG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STAGING="$WORK/staging"
mkdir "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$PACKAGING/dmg-background.png" "$STAGING/.background/background.png"

# Read-write image first so Finder can persist the window layout, then convert.
RW="$WORK/rw.dmg"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -fs HFS+ -ov -format UDRW "$RW" >/dev/null

MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/.*' | head -n 1)"
[ -n "$MOUNT" ] || { echo "error: could not mount $RW" >&2; exit 1; }
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
DISK="$(basename "$MOUNT")"

# Geometry contract with make-dmg-background.sh: 660x420 pt window, icons at
# (165, 205) and (495, 205). Retried because Finder can lag a fresh mount.
layout() {
    osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- Bounds include the ~28 pt title bar; +28 so the 660x420
        -- background exactly fills the content area below it.
        set the bounds of container window to {200, 120, 860, 568}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.png"
        set position of item "$APP_NAME" of container window to {165, 205}
        set position of item "Applications" of container window to {495, 205}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
}
for attempt in 1 2 3; do
    layout && break
    [ "$attempt" -eq 3 ] && { echo "error: Finder layout failed after $attempt attempts" >&2; exit 1; }
    echo "warning: Finder layout attempt $attempt failed, retrying" >&2
    sleep 2
done

# Volume icon last: the Finder layout pass above deletes .VolumeIcon.icns and
# clears the custom-icon flag if they are set before it runs.
cp "$PACKAGING/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT" || echo "warning: SetFile unavailable, no volume icon" >&2

sync
for attempt in 1 2 3 4 5; do
    hdiutil detach "$MOUNT" >/dev/null 2>&1 && break
    [ "$attempt" -eq 5 ] && hdiutil detach "$MOUNT" -force >/dev/null
    sleep 2
done
trap 'rm -rf "$WORK"' EXIT

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
