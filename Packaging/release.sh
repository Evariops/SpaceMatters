#!/bin/bash
# Build a signed + notarized DMG and publish it as a GitHub Release (SPEC-07 v1).
#
# NOTE: the normal path is now CI — Release Drafter keeps a draft release up to
# date, and publishing it triggers .github/workflows/release.yml which builds
# and attaches the DMG. Keep this script for fully-local releases (it *creates*
# the release, so don't mix it with an already-published draft for the same tag).
#
# One-time external prerequisites:
#   - An Apple "Developer ID Application" certificate in your login keychain.
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials spacematters-notary \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#   - GitHub CLI authenticated: gh auth login
#
# Environment:
#   DEVELOPER_ID    "Developer ID Application: Your Name (TEAMID)"   (required)
#   NOTARY_PROFILE  keychain profile name                            (default: spacematters-notary)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-spacematters-notary}"

APP="SpaceMatters.app"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
[ -z "$VERSION" ] && { echo "error: tag the release first, e.g. git tag v1.0.0" >&2; exit 1; }
DMG="SpaceMatters-${VERSION}.dmg"

echo "▸ Building & bundling ${VERSION} with ${DEVELOPER_ID}"
# bundle.sh signs everything inner→outer (Sparkle helpers, framework, app) and
# turns on hardened runtime + timestamp for Developer ID identities itself —
# the stable identity is what makes the Full Disk Access grant persist.
CODESIGN_ID="$DEVELOPER_ID" ./Packaging/bundle.sh release
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Update archive (Sparkle): notarize app via zip, staple, re-zip"
ZIP="SpaceMatters-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "▸ Building DMG (from the stapled app)"
./Packaging/make-dmg.sh "$APP" "$DMG"

echo "▸ Signing, notarizing & stapling DMG (this can take a few minutes)"
codesign --force --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" || true

echo "▸ Publishing GitHub Release v${VERSION}"
gh release create "v${VERSION}" "$DMG" "$ZIP" \
  --title "SpaceMatters ${VERSION}" \
  --notes "Signed & notarized build. Download the .dmg, open it, and drag SpaceMatters into Applications. macOS opens it without a Gatekeeper warning."

echo "▸ Sparkle appcast (cumulative, EdDSA-signed)"
./Packaging/make-appcast.sh "$VERSION" "$ZIP"
gh release upload "v${VERSION}" appcast.xml --clobber

echo "✓ Released v${VERSION} → ${DMG} + ${ZIP} + appcast.xml"
