#!/bin/bash
# Package an .app bundle into a compressed DMG with an /Applications alias.
# Shared by release.sh (local) and .github/workflows/release.yml (CI).
# Usage: Packaging/make-dmg.sh <App.app> <output.dmg>
set -euo pipefail

APP="${1:?usage: make-dmg.sh <App.app> <output.dmg>}"
DMG="${2:?usage: make-dmg.sh <App.app> <output.dmg>}"
VOLNAME="$(basename "$APP" .app)"

rm -f "$DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
