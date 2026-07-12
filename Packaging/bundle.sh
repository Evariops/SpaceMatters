#!/bin/bash
# Build SpaceMatters and assemble a double-clickable SpaceMatters.app bundle.
# Lives in Packaging/ but works from the repo root: the bundle is written there.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="SpaceMatters.app"
BIN_NAME="SpaceMatters"

echo "Building (${CONFIG})..."
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$BIN_NAME"

echo "Assembling ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"

# Sparkle auto-update framework (SPEC-12). SwiftPM resolves the XCFramework;
# the binary links @rpath/Sparkle.framework and carries an rpath pointing at
# Contents/Frameworks (Package.swift linkerSettings).
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || { echo "error: Sparkle.framework not found at $SPARKLE_SRC (run swift build first)" >&2; exit 1; }
echo "Embedding Sparkle.framework..."
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Not sandboxed → Sparkle's XPC services are never used (they are opt-in via
# SUEnable*Service plist keys we don't set); headers are build-time only.
# Both the payloads and their top-level symlinks go, ~650 KB saved.
rm -rf "$FRAMEWORK/Versions/B/XPCServices"    "$FRAMEWORK/XPCServices" \
       "$FRAMEWORK/Versions/B/Headers"        "$FRAMEWORK/Headers" \
       "$FRAMEWORK/Versions/B/PrivateHeaders" "$FRAMEWORK/PrivateHeaders" \
       "$FRAMEWORK/Versions/B/Modules"        "$FRAMEWORK/Modules"

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
# Interpolated into the Info.plist heredoc below: keep them plist-safe so a
# hostile tag name can't inject XML.
VERSION="$(printf '%s' "$VERSION" | tr -cd '0-9A-Za-z.-')"
BUILD="$(printf '%s' "$BUILD" | tr -cd '0-9')"
[ -z "$BUILD" ] && BUILD=1

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SpaceMatters</string>
    <key>CFBundleDisplayName</key>     <string>SpaceMatters</string>
    <key>CFBundleIdentifier</key>      <string>com.spacematters.app</string>
    <key>CFBundleExecutable</key>      <string>SpaceMatters</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
${ICON_KEY}
    <key>LSMinimumSystemVersion</key>  <string>15.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <!-- Sparkle auto-update (SPEC-12). CFBundleVersion above (commit count,
         monotonic) is what Sparkle compares as sparkle:version. The updater
         never checks before the user accepts Sparkle's second-launch prompt. -->
    <key>SUFeedURL</key>               <string>https://github.com/Evariops/SpaceMatters/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>           <string>giAqx0Y+CIUuSvv4DDNfJnC/wF16Y71qi03XF3LZx30=</string>
    <!-- TCC usage descriptions (J1.4): shown when macOS prompts for access. -->
    <key>NSDesktopFolderUsageDescription</key>     <string>SpaceMatters measures the size of your Desktop to show what's using disk space.</string>
    <key>NSDocumentsFolderUsageDescription</key>   <string>SpaceMatters measures the size of your Documents to show what's using disk space.</string>
    <key>NSDownloadsFolderUsageDescription</key>   <string>SpaceMatters measures the size of your Downloads to show what's using disk space.</string>
    <key>NSRemovableVolumesUsageDescription</key>  <string>SpaceMatters scans external drives you choose to analyze their disk usage.</string>
    <key>NSNetworkVolumesUsageDescription</key>    <string>SpaceMatters scans network volumes you choose to analyze their disk usage.</string>
</dict>
</plist>
PLIST

# Sign the app. Ad-hoc ("-") works but its identity (cdhash) changes on every
# rebuild, so macOS TCC grants like Full Disk Access don't persist across builds.
# Set CODESIGN_ID to a stable self-signed identity to keep those grants:
#   1) Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
#      name "SpaceMatters", type "Code Signing", self-signed.
#   2) export CODESIGN_ID="SpaceMatters"   (then re-run ./Packaging/bundle.sh)
SIGN_ID="${CODESIGN_ID:--}"
# Hardened runtime requires a real Team ID: without one (ad-hoc or self-signed)
# library validation rejects the embedded Sparkle.framework and dyld kills the
# app at launch ("different Team IDs" — SPEC-12 §6.1). Developer ID also gets a
# secure timestamp, which notarization requires.
RUNTIME_FLAGS=""
case "$SIGN_ID" in
    "Developer ID Application:"*) RUNTIME_FLAGS="--options runtime --timestamp" ;;
esac
# Nested code first, outer bundle last — Apple deprecates --deep, and the
# framework's helpers (Autoupdate, Updater.app) must carry their own signature.
echo "Signing (identity: ${SIGN_ID})..."
# shellcheck disable=SC2086  # RUNTIME_FLAGS is deliberately word-split
for TARGET in \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK" \
    "$APP"; do
    if ! codesign --force $RUNTIME_FLAGS --sign "$SIGN_ID" "$TARGET" >/dev/null 2>&1; then
        echo "error: codesign failed for identity '${SIGN_ID}' on ${TARGET}" >&2
        exit 1
    fi
done
codesign --verify --strict "$APP" || { echo "error: strict verification failed" >&2; exit 1; }

echo "Done → $PWD/$APP  (signed with: ${SIGN_ID})"
echo "Launch with: open $APP"
