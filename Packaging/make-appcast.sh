#!/bin/bash
# Build/refresh the Sparkle appcast for one release (SPEC-12).
# Usage: Packaging/make-appcast.sh <version> <zip-path>
#
# Cumulative feed: the previous release's appcast.xml is downloaded and
# generate_appcast appends the new entry to it — existing entries keep their
# absolute per-tag URLs untouched (verified, SPEC-12 §6.1). First Sparkle
# release simply starts a fresh feed. --maximum-versions (default 3) prunes
# the tail.
#
# Release notes: the GitHub release body (markdown, written by Release
# Drafter) is embedded as <description sparkle:format="markdown"> via an
# adjacent .md file + --embed-release-notes.
#
# EdDSA key: $SPARKLE_ED_PRIVATE_KEY if set (CI secret, seed format), else
# the login keychain entry created by generate_keys (local use).
#
# Writes appcast.xml to the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-appcast.sh <version> <zip-path>}"
ZIP="${2:?usage: make-appcast.sh <version> <zip-path>}"
TAG="v${VERSION}"
REPO="${GH_REPO:-Evariops/SpaceMatters}"

GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || { echo "error: $GENERATE_APPCAST not found (run swift build first)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ZIP" "$WORK/"

# Release notes from the published release body (may legitimately be empty).
NOTES="$WORK/$(basename "$ZIP" .zip).md"
gh release view "$TAG" --repo "$REPO" --json body --jq .body > "$NOTES" || true
[ -s "$NOTES" ] || rm -f "$NOTES"

# Previous cumulative appcast: newest earlier release that shipped one.
for PREV in $(gh release list --repo "$REPO" --exclude-drafts --json tagName --jq '.[].tagName'); do
    [ "$PREV" = "$TAG" ] && continue
    if gh release download "$PREV" --repo "$REPO" --pattern appcast.xml --dir "$WORK" 2>/dev/null; then
        echo "Extending appcast from ${PREV}"
        break
    fi
done

ARGS=(
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/"
    --link "https://github.com/$REPO"
    --embed-release-notes
)
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${ARGS[@]}" "$WORK"
else
    "$GENERATE_APPCAST" "${ARGS[@]}" "$WORK"
fi

mv "$WORK/appcast.xml" appcast.xml
echo "✓ appcast.xml ($(grep -c '<item>' appcast.xml) entries)"
