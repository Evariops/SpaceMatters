#!/bin/bash
# Build a signed + notarized DMG and publish it as a GitHub Release (SPEC-07 v1).
#
# One-time external prerequisites:
#   - An Apple "Developer ID Application" certificate in your login keychain.
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials macdirstats-notary \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   - GitHub CLI authenticated: gh auth login
#
# Environment:
#   DEVELOPER_ID    "Developer ID Application: Your Name (TEAMID)"   (required)
#   NOTARY_PROFILE  keychain profile name                            (default: macdirstats-notary)
set -euo pipefail
cd "$(dirname "$0")"

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-macdirstats-notary}"

APP="MacDirStats.app"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
[ -z "$VERSION" ] && { echo "error: tag the release first, e.g. git tag v1.0.0" >&2; exit 1; }
DMG="MacDirStats-${VERSION}.dmg"

echo "▸ Building & bundling ${VERSION} with ${DEVELOPER_ID}"
# Bundle (icon, plist, git version) signed with the Developer ID — the stable
# cdhash is what makes the Full Disk Access grant persist across builds.
CODESIGN_ID="$DEVELOPER_ID" ./bundle.sh release

echo "▸ Hardened-runtime sign + verify"
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Building DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "MacDirStats" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "▸ Signing, notarizing & stapling DMG (this can take a few minutes)"
codesign --force --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" || true

echo "▸ Publishing GitHub Release v${VERSION}"
gh release create "v${VERSION}" "$DMG" \
  --title "MacDirStats ${VERSION}" \
  --notes "Signed & notarized build. Download the .dmg, open it, and drag MacDirStats into Applications. macOS opens it without a Gatekeeper warning."

echo "✓ Released v${VERSION} → ${DMG}"
