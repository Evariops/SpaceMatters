#!/bin/bash
# Build MacDirStats and assemble a double-clickable MacDirStats.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="MacDirStats.app"
BIN_NAME="MacDirStats"

echo "Building (${CONFIG})..."
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

# App icon (J1.2). Regenerate with ./Packaging/make-icon.sh if the look changes.
ICON_KEY=""
if [ -f "Packaging/AppIcon.icns" ]; then
    cp "Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>        <string>AppIcon</string>"
fi

# Version derived from git so About/Finder reflect the actual build (J1.5).
# CI overrides VERSION from the release tag (git describe needs local tags).
# The `|| true` keeps `set -o pipefail` from aborting when there's no tag yet.
VERSION="${VERSION:-$( { git describe --tags --abbrev=0 2>/dev/null || true; } | sed 's/^v//')}"
[ -z "$VERSION" ] && VERSION="0.1.0"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MacDirStats</string>
    <key>CFBundleDisplayName</key>     <string>MacDirStats</string>
    <key>CFBundleIdentifier</key>      <string>com.macdirstats.app</string>
    <key>CFBundleExecutable</key>      <string>MacDirStats</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
${ICON_KEY}
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <!-- TCC usage descriptions (J1.4): shown when macOS prompts for access. -->
    <key>NSDesktopFolderUsageDescription</key>     <string>MacDirStats measures the size of your Desktop to show what's using disk space.</string>
    <key>NSDocumentsFolderUsageDescription</key>   <string>MacDirStats measures the size of your Documents to show what's using disk space.</string>
    <key>NSDownloadsFolderUsageDescription</key>   <string>MacDirStats measures the size of your Downloads to show what's using disk space.</string>
    <key>NSRemovableVolumesUsageDescription</key>  <string>MacDirStats scans external drives you choose to analyze their disk usage.</string>
    <key>NSNetworkVolumesUsageDescription</key>    <string>MacDirStats scans network volumes you choose to analyze their disk usage.</string>
</dict>
</plist>
PLIST

# Sign the app. Ad-hoc ("-") works but its identity (cdhash) changes on every
# rebuild, so macOS TCC grants like Full Disk Access don't persist across builds.
# Set CODESIGN_ID to a stable self-signed identity to keep those grants:
#   1) Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#      name "MacDirStats", type "Code Signing", self-signed.
#   2) export CODESIGN_ID="MacDirStats"   (then re-run ./bundle.sh)
SIGN_ID="${CODESIGN_ID:--}"
# Prefer a hardened runtime; fall back without it (needed for a debuggable
# ad-hoc build). Only a *total* signing failure is fatal — don't mask it.
if codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
    :
elif codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
    echo "note: signed without hardened runtime"
else
    echo "error: codesign failed for identity '${SIGN_ID}'" >&2
    exit 1
fi

echo "Done → $PWD/$APP  (signed with: ${SIGN_ID})"
echo "Launch with: open $APP"
