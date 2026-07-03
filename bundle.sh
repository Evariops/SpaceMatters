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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MacDirStats</string>
    <key>CFBundleDisplayName</key>     <string>MacDirStats</string>
    <key>CFBundleIdentifier</key>      <string>com.macdirstats.app</string>
    <key>CFBundleExecutable</key>      <string>MacDirStats</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
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
