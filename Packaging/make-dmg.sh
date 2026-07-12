#!/bin/bash
# Package an .app bundle into a styled, compressed DMG: background picture
# with a drag-to-Applications hint, positioned icons and a custom volume icon.
# The window layout ships as a committed asset (Packaging/dmg.DS_Store, built
# by dmg-assets.swift), so packaging is two headless hdiutil calls —
# no Finder scripting, no mounting, deterministic.
# Shared by Packaging/release.sh (local) and .github/workflows/release.yml (CI).
# Usage: Packaging/make-dmg.sh <App.app> <output.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <App.app> <output.dmg>}"
DMG="${2:?usage: make-dmg.sh <App.app> <output.dmg>}"
VOLNAME="$(basename "$APP" .app)"
PACKAGING="$(cd "$(dirname "$0")" && pwd)"

# dmg.DS_Store embeds the volume name (in the background picture alias):
# a different volume would silently lose the background for end users.
if [ "$VOLNAME" != "SpaceMatters" ]; then
    echo "error: dmg.DS_Store is baked for volume 'SpaceMatters', not '$VOLNAME'" \
         "— update and re-run dmg-assets.swift" >&2
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
cp "$PACKAGING/dmg.DS_Store" "$STAGING/.DS_Store"
cp "$PACKAGING/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
xcrun SetFile -a C "$STAGING" || echo "warning: SetFile unavailable, no volume icon" >&2

# makehybrid rather than create -srcfolder: it carries the staging folder's
# custom-icon flag onto the volume root, which create drops.
hdiutil makehybrid -hfs -default-volume-name "$VOLNAME" -o "$WORK/raw.dmg" "$STAGING"
hdiutil convert "$WORK/raw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
