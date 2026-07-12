# SPEC-07 — Distribution: signed + notarized DMG via GitHub

> **Findings**: J1.1 (no release binary), J1.2 (generic icon), J1.4 (missing TCC usage descriptions), J1.5 (version/About), D4 (signing/notarization). I3 (`bundle.sh` `|| true`) **already fixed**.
> **v1 scope (imposed)**: distribute **only a `.dmg` via GitHub Releases**. No Mac App Store. Homebrew Cask / auto-update pushed out of v1.
> **Status**: ✅ **IMPLEMENTED** (everything codable) — signing/notarization runnable once the Developer ID account is provided (external prerequisite).

## 0. Implementation result

- **Icon** (J1.2): [`Packaging/make-icon.sh`](../../Packaging/make-icon.sh) renders `chart.pie.fill` (accent on a panel background) → `Packaging/AppIcon.icns` (generated, committed); `bundle.sh` copies it + `CFBundleIconFile`. Verified visually.
- **TCC usage descriptions** (J1.4): `NSDesktop/Documents/Downloads/RemovableVolumes/NetworkVolumes UsageDescription` added to the plist. `plutil -lint` OK.
- **Version from git** (J1.5): `CFBundleShortVersionString` = `git describe --tags` (fallback `0.1.0`), `CFBundleVersion` = number of commits. Verified (`0.1.0` / build `26`).
- **`release.sh`**: build → `bundle.sh` (Developer ID) → **hardened-runtime sign + verify** → DMG (`hdiutil`, app + `/Applications` alias) → sign DMG → `notarytool submit --wait` → `stapler staple` → `spctl` check → **`gh release create`**. External prerequisites documented at the top (Developer ID cert + `notarytool` profile + `gh auth`).
- **README**: "Download" section pointing to `releases/latest`.
- **`.gitignore`**: `*.dmg` (artifact) excluded; `MacDirStats.app/` already excluded.
- **🔬 Not runnable here**: the Developer ID signing + notarization require an Apple Developer account (external prerequisite assumed by spec §6). The ad-hoc fallback of `bundle.sh` remains for local dev (verified: ad-hoc-signed bundle launches without crash).

## 1. Objective

A colleague downloads the `.dmg` from the **GitHub Releases** page, mounts it, drags the app into Applications, and opens it **without a Gatekeeper block** — so a **Developer ID signed + notarized + stapled** DMG.

## 2. Current state (verified)

- `bundle.sh`: **ad-hoc** signing (unstable cdhash → FDA to re-grant), **no** notarization, **no** `.icns`/`CFBundleIconFile`, `CFBundleShortVersionString` frozen at "1.0", bundle id `com.macdirstats.app`. Total failure of `codesign` **now unmasked** (I3 done).
- No `NS*UsageDescription` key → bare TCC prompts (J1.4).
- FDA detection via opening `TCC.db` ([FullDiskAccess.swift](../../Sources/SpaceMatters/Util/FullDiskAccess.swift)) — well documented; sensitive to the cdhash → **stable signing (Developer ID) makes the FDA grant persist**, a big gain vs ad-hoc.

## 3. Implementation plan (v1)

1. **Icon** (J1.2): `AppIcon.icns` (the `chart.pie.fill` pie chart from the splash works) + `CFBundleIconFile` in `bundle.sh`.
2. **TCC usage descriptions** (J1.4): add to the generated plist `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` — explicit phrasing.
3. **Version from git** (J1.5): `CFBundleShortVersionString`/`CFBundleVersion` derived from `git describe --tags` at build time; small custom About panel.
4. **Developer ID signing + notarization**:
   - `codesign --force --options runtime --sign "Developer ID Application: …" MacDirStats.app`
   - build the DMG (`hdiutil create` or `create-dmg`) with the app + `/Applications` alias
   - `codesign` the DMG, `xcrun notarytool submit MacDirStats.dmg --keychain-profile … --wait`, then `xcrun stapler staple MacDirStats.dmg`.
5. **`release.sh` script**: release build → bundle → sign → dmg → notarize → staple → `gh release create vX.Y.Z MacDirStats.dmg --notes …`.
6. **README**: "Download" section pointing to the latest GitHub Release.

## 4. Out of v1 scope (to keep in mind)

- Homebrew Cask (`brew install --cask macdirstats`) — trivial once Releases are in place.
- Auto-update (Sparkle appcast **or** simple "check GitHub releases").
- Mac App Store (sandbox incompatible with the global disk scan — not relevant).

## 5. Verification

- `spctl -a -vv -t open --context context:primary-signature MacDirStats.dmg` → "accepted, source=Notarized Developer ID".
- `codesign -dv --verbose=4 MacDirStats.app` → Developer ID identity, hardened runtime.
- **Real test**: download the DMG from the GitHub Release on **another** session/machine → opens without "unidentified developer".
- Verify that the FDA grant **persists** after a signed rebuild (stable cdhash).

## 6. Risks & assumptions

- External prerequisite: Apple Developer account (Developer ID Application) + `notarytool` keychain profile.
- 🔬 Hardened runtime vs local debuggability: keep the ad-hoc fallback of `bundle.sh` for dev builds; the signed/notarized path is reserved for `release.sh`.

## 7. Effort & dependencies

**1–2 days** (excluding obtaining the Developer account). Independent.
