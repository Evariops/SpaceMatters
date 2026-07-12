# SPEC-12 — Auto-update: Sparkle 2

> **Context**: SPEC-07 delivered the v1 distribution (Developer ID signed DMG + notarized + stapled via GitHub Releases) and explicitly listed auto-update as out of scope (§4). This spec closes that workstream.
> **v1 scope**: consented automatic check + manual "Check for Updates…", in-place update from GitHub Releases, release notes displayed. Beta channel, deltas and Settings pane deferred (§3.8).
> **Product constraint (2026-07-12)**: no Apple Developer account for now, decision deferred as long as possible **without closing the door** — hence the two-track identity strategy of §3.7: self-signed stable today, switch to Developer ID by simply adding secrets, transparent transition for updates (EdDSA chain).
> **Status**: ✅ **implemented and validated live on 2026-07-12** (branch `feat/spec12-sparkle-updates`, not pushed) — milestones §4.1–4.7 done; **full update cycle proven on this machine**: v0.0.1 from `~/Applications` → "Check for Updates…" → detection of v9.9.9, markdown notes rendered, download, EdDSA validation, in-place replacement, **quarantine lifted** (0 xattr), **automatic relaunch** in 9.9.9. **FDA track A persistence proven** (identical cert-pinned DR, grant survives the update, §5). Consent prompt on 2nd launch confirmed (the observed absence = already-answered state, not a bug). All 🔬 assumptions lifted (§6). **Remaining before public release**: creation of the cert in the CI's ephemeral keychain (1st run), first real release. Relaunch note: does not trigger from `/private/tmp` (LaunchServices) — no effect in `~/Applications`/`/Applications`.

## 1. Objective

The user who installed SpaceMatters from the DMG is notified that a new version exists, reads the release notes, clicks "Install" — the app replaces itself in place, relaunches, **without re-passing Gatekeeper and without losing the Full Disk Access grant**. All of this without any network connection leaving before their explicit consent.

Chosen framework: **[Sparkle 2](https://github.com/sparkle-project/Sparkle)** (2.9.4 at the time of writing). **MIT** license (+ BSD 2-clause for bsdiff/bspatch, MIT for ed25519 — verified on the 2.x branch): compatible with Apache 2.0, no obligation beyond preserving the copyright notices.

## 2. Current state of the code (verified)

- **Complete and functional release chain** (SPEC-07): [release.sh](../../Packaging/release.sh) locally, [release.yml](../../.github/workflows/release.yml) in CI (triggered on draft publication) — build → `bundle.sh` → sign hardened-runtime → DMG → notarize → staple → upload asset. Three tagged releases (v0.1.0 → v0.3.0).
- **Release notes already produced**: [release-drafter.yml](../../.github/workflows/release-drafter.yml) maintains a markdown draft, categorized by PR labels — the raw material for update notes already exists, it just needs to be routed to the appcast.
- **Versioning compatible with Sparkle as-is**: `CFBundleShortVersionString` = semver tag ([Packaging/bundle.sh:49](../../Packaging/bundle.sh#L49)), `CFBundleVersion` = **commit count** ([Packaging/bundle.sh:32](../../Packaging/bundle.sh#L32), `fetch-depth: 0` in CI for that, [release.yml:45](../../.github/workflows/release.yml#L45)) — integer, strictly increasing on `main`: directly usable as `sparkle:version`.
- **Handcrafted bundle, single static binary**: `bundle.sh` generates the Info.plist via heredoc ([Packaging/bundle.sh:39-64](../../Packaging/bundle.sh#L39-L64)), no `Contents/Frameworks`, no rpath. Current signature via `codesign --deep` ([Packaging/bundle.sh:75](../../Packaging/bundle.sh#L75), [Packaging/release.sh](../../Packaging/release.sh#L36)) — will need to become explicit (inner→outer) with an embedded framework.
- **No sandbox, no entitlements** (verified: no `.entitlements`, no `com.apple.security.*`): Sparkle's XPC services are useless here, integration simplified.
- **No network code in the app**: zero `URLSession` in `Sources/`. Sparkle will be the app's **first outbound connection** — the house ethos is explicit ([NativeCleaner.swift:53](../../Sources/SpaceMatters/Scanner/NativeCleaner.swift#L53): "a cleaner must not update taps or phone home"), so consent first, README transparency next.
- **UI anchor points**: GUI entry point [SpaceMattersApp.swift:40-56](../../Sources/SpaceMatters/App/SpaceMattersApp.swift#L40-L56) (caution: the `@main` `Entry` enum also routes headless CLI subcommands — the updater must only live in the GUI path); a single `.commands` block ([SpaceMattersApp.swift:49-55](../../Sources/SpaceMatters/App/SpaceMattersApp.swift#L49-L55)); no Settings scene (ad-hoc settings via `@AppStorage`).
- **FDA keyed on the signature**: the Developer ID designated requirement is stable → the TCC grant survives a bundle replacement by Sparkle (same identity, same bundle id). This is precisely the scenario that SPEC-07's stable signature makes possible.

## 3. Design axes & tradeoffs

### 3.1 Sparkle vs "home-made check" GitHub API

A home-made check (query `releases/latest`, offer the download) would avoid the dependency — but everything of value is in the install: atomic replacement of the bundle, signature validation, **quarantine lifting**, clean relaunch. Reimplementing that means rewriting Sparkle's most sensitive code without its ten years of hardening. Sparkle is the de facto standard outside the App Store (iTerm2, Transmit…), its license is trivial, and it is consumed as an SPM dependency (binary XCFramework). **Decision: Sparkle 2.**

### 3.2 Update deliverable: a dedicated zip, the DMG stays for the human

The DMG (styled background, drag-to-Applications) remains the channel for the **first** download. For the appcast, we additionally publish a **zip** created by `ditto -c -k --sequesterRsrc --keepParent` (symlink preservation, required by the Sparkle docs so as not to break the signature). Sparkle can consume a DMG, but the zip is faster to extract, and it is the input format for `generate_appcast` deltas if we enable them later.

### 3.3 Appcast hosting

| Option | Pro | Con |
|---|---|---|
| **A. Release asset, URL `releases/latest/download/appcast.xml`** ✅ | Zero infra, same pipeline as the DMG, stable URL (302 redirect followed by Sparkle) | Pulling a faulty release = re-uploading the asset; `latest` ignores prereleases (to revisit for a beta channel) |
| B. `gh-pages` branch + GitHub Pages | Feed independent of releases, patchable without re-release | A branch and a Pages deployment to maintain for one file |
| C. Commit on `main`, served by raw.githubusercontent | — | CI pushing to `main`: no |

**Decision: A.** `SUFeedURL = https://github.com/Evariops/SpaceMatters/releases/latest/download/appcast.xml`. `generate_appcast` preserves the entries of an existing appcast: CI downloads the previous release's appcast, adds the new entry, re-uploads the accumulation — the old absolute URLs (per tag) remain valid.

### 3.4 Chain of trust, quarantine, notarization

- **EdDSA**: `generate_keys` (once, locally) → public key in the plist (`SUPublicEDKey`), private key exported (`generate_keys -x`) to a GitHub secret `SPARKLE_ED_PRIVATE_KEY` (read by `generate_appcast --ed-key-file -` on stdin) **and saved outside GitHub** (keychain + vault): since the public key is baked into every installed app, losing it makes existing clients unable to update.
- Sparkle verifies **EdDSA + the Apple signature** (the update must be signed by the same team as the installed app): even a compromised GitHub account cannot push an accepted update without the EdDSA private key.
- **Quarantine**: the zip downloaded by Sparkle receives `com.apple.quarantine` like any download; Sparkle itself validates both signatures then **removes the attribute at install time** — the updated app relaunches without re-passing Gatekeeper or app translocation. This is the central mechanism the home-made check would not have.
- **Notarizing the zip anyway** *(track B only — without an Apple account this point drops, and Sparkle doesn't need it)*: the Sparkle flow doesn't require it (quarantine lifted), but the same zip is downloadable by hand from the Release page. So we notarize **the app before zipping**: `ditto` → `notarytool submit` of the zip → `stapler staple` on the `.app` → re-`ditto` of the final zip → the DMG is then built from the stapled app (the existing DMG flow doesn't change, its submission becomes near-instant, content already ticketed).

### 3.5 Release notes: the release-drafter draft, rendered by Sparkle

Sparkle 2.9+ renders **markdown** natively (`<description sparkle:format="markdown">`). No post-processing to write: `generate_appcast` consumes a **`.md` file adjacent to the archive** (same base name: `SpaceMatters-X.Y.Z.md`) and, with `--embed-release-notes`, embeds it as-is in `<description sparkle:format="markdown">` — **verified by running the tool** (§6.1). CI writes this file from `gh release view --json body`. Rendering constraint (source read, §6.2): it's a native `NSAttributedString` text rendering, not WKWebView — lists, links and emphasis pass; tables and raw HTML do not. Release-drafter produces only lists with links → compatible. Fallback if the rendering disappoints visually: `<sparkle:releaseNotesLink>` to the GitHub release page.

### 3.6 UX: consent first

- **Instantiation**: `SPUStandardUpdaterController(startingUpdater: true, …)` owned by `SpaceMattersApp` (GUI path only — never in `Entry`'s CLI subcommands).
- **Menu**: "Check for Updates…" via `CommandGroup(after: .appInfo)` in the existing `.commands` block, enabled/disabled by `updater.publisher(for: \.canCheckForUpdates)` (small observable `UpdaterModel`).
- **Automatic check**: we keep the standard Sparkle behavior — **consent prompt on the second launch**, no check before agreement. `SUEnableAutomaticChecks` deliberately absent from the plist (forcing it would short-circuit the prompt). Aligned with the no-phone-home ethos; the README documents what the check does (appcast request, no telemetry).
- No Settings scene in v1: the Sparkle prompt + the menu suffice; a toggle in a future Settings scene (`automaticallyChecksForUpdates`) will come with other settings.

### 3.7 Signing identity: self-signed first, Developer ID when we want it

Product decision: defer the Apple Developer account (99 $/year) as long as possible, without closing the door. Two tracks, **same architecture** — the update chain of trust is EdDSA in both cases, the Apple identity is just a parameter:

**Track A — now, free: stable self-signed certificate.**
- Create a self-signed "SpaceMatters" code-signing certificate (Keychain ▸ Certificate Assistant, the one [Packaging/bundle.sh:68-71](../../Packaging/bundle.sh#L68-L71) already documents) — **long validity (3650 days)**, not the default 365: at expiry, changing certificate = new designated requirement = FDA re-requested.
- Export it as `.p12` → repo secrets `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` (the **same names** as for Developer ID: track B will literally consist of replacing the secret's content).
- Signature **without hardened runtime** (proven §6.1: without a Team ID, library validation kills the app at launch); no notarization (impossible without an account, and useless: Sparkle lifts the update quarantine itself, §6.2).
- What it guarantees: stable designated requirement (the cert is embedded in the signature) → **FDA persists across updates**; identity accepted by `generate_appcast` (ad-hoc passes, proven §6.1) and by Sparkle client-side validation.
- What it costs: hostile first install on macOS 15 (no more right-click ▸ Open: Settings ▸ Privacy ▸ "Open anyway"), to document honestly in the README. Once installed, no more Gatekeeper passage.

**Track B — later, 99 $/year: Developer ID + notarization.**
- Replace the secrets' `.p12` with the Developer ID certificate and add `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_SPECIFIC_PASSWORD` — the workflow is already conditional (`HAS_SIGNING`/`HAS_NOTARY`), notarization activates on its own.
- Re-enable `--options runtime` (conditioned in the scripts: hardened runtime **if and only if** the identity is "Developer ID Application: *").

**The A→B transition is safe for the installed base** (source read + confirmed on 2026-07-12): `validateUpdateForHost` (`SUUpdateValidator.m:306`) decides on `passedDSACheck || passedCodeSigning` — a valid EdDSA suffices, an update whose code-signing identity differs from the installed app is accepted as long as its own signature is valid (the "same identity" check is only a fallback when EdDSA is missing). Our EdDSA key does not change → the self-signed base accepts a Developer ID update. One-time cost of the switch: the designated requirement changes → **FDA re-requested once** per user; to mention in the notes of the transition release.

To adapt in [release.yml](../../.github/workflows/release.yml): the identity extraction ([release.yml:67-68](../../.github/workflows/release.yml#L67-L68)) only matches `Developer ID Application:` **and** uses `find-identity -v`, which masks an untrusted self-signed cert (observed on 2026-07-12: the SpaceMatters identity appears as `CSSMERR_TP_NOT_TRUSTED` without `-v`, invisible with it, whereas `codesign` signs perfectly with it). → drop the `-v`, match any code-signing identity, and condition `--options runtime` + notarization on the `Developer ID Application:` pattern.

### 3.8 Out of scope for v1

- **Binary deltas**: `generate_appcast` produces them for free if we give it the N previous zips — to enable when the app grows (a few MB today, marginal gain).
- **Beta channel** (`sparkle:channel`) — will require revisiting option A of §3.3 (`latest` ignores prereleases).
- **Homebrew Cask** (`auto_updates true` once Sparkle is in place).

## 4. Implementation plan

1. **[Package.swift](../../Package.swift)**: dependency `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")`, produces `Sparkle` on the executable target, rpath `@executable_path/../Frameworks` via `linkerSettings` (the target already uses `unsafeFlags`, no new constraint). Dev and tests require **no other setting**: SwiftPM copies the framework next to the build binary and lays down a `@loader_path` rpath (verified §6.1).
2. **[Packaging/bundle.sh](../../Packaging/bundle.sh)**: between the binary copy and the signature — create `Contents/Frameworks/`, copy `Sparkle.framework` into it from `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/` (observed path), **remove `Versions/B/XPCServices/`** (424 KB, useless outside sandbox — §6.2) as well as `Headers/`, `PrivateHeaders/` and `Modules/` (224 KB, useless at runtime); optional: `lipo -thin arm64` on the framework's three Mach-O files (the app is already distributed arm64-only — native `swift build`, arm64 CI runner), gain ≈ 1 MB installed / 0.4 MB downloaded; add `SUFeedURL` and `SUPublicEDKey` to the plist heredoc (**mandatory before building a release: without `SUPublicEDKey` in the archived app, `generate_appcast` emits no signature** — §6.1); replace the `codesign --deep` with an explicit inner→outer signature (`Autoupdate`, `Updater.app`, the framework, then the app) — same thing in [Packaging/release.sh](../../Packaging/release.sh#L36). ⚠️ **`--options runtime` only if the identity is Developer ID** (track B): without a Team ID — ad-hoc dev like the track A self-signed certificate — library validation kills the app at launch (`different Team IDs`, proven §6.1).
3. **Swift code**: `UpdaterModel` (wrapping `SPUStandardUpdaterController` + published `canCheckForUpdates`), instantiated in `SpaceMattersApp`, menu item in `.commands`.
4. **Keys**: ✅ **done on 2026-07-12** — EdDSA pair generated (`generate_keys`): private in the session keychain (item "Private key for signing Sparkle updates") **and** repo secret `SPARKLE_ED_PRIVATE_KEY`; public to bake into `bundle.sh`'s heredoc:
   ```xml
   <key>SUPublicEDKey</key>    <string>giAqx0Y+CIUuSvv4DDNfJnC/wF16Y71qi03XF3LZx30=</string>
   ```
   ✅ Vault backup done (2026-07-12). The private key exists in three copies: session keychain, repo secret, vault.
5. **Self-signed certificate (track A, §3.7)**: ✅ **created on 2026-07-12** (openssl: CN=SpaceMatters, RSA 2048, critical code-signing EKU, **valid until 2036-07-09**), imported into the session keychain, signature tested (`Authority=SpaceMatters`, designated requirement pinned `certificate leaf = H"6ec027a9795823a6b14b4c84d209f2ebf16fe27f"`). `.p12` + password in `~/Documents/SpaceMatters-signing-backup/` — **to move to the vault then delete from disk** (lost cert = FDA re-requested for all users). ✅ Repo secrets `MACOS_CERT_P12` + `MACOS_CERT_PASSWORD` set (2026-07-12) — the track A inventory is complete with `SPARKLE_ED_PRIVATE_KEY`. ✅ Identity extraction broadened (without `-v`) and runtime/notarization conditioned on the identity type in `release.yml`.
   > **Implementation (2026-07-12)**: milestones 1–7 completed on `feat/spec12-sparkle-updates` — scripts moved into `Packaging/` (+ shared CI/local `make-appcast.sh`), 102 green tests, release bundle signed `SpaceMatters` verified strict + launched, CI appcast wired. Keychain pitfall noted along the way: a `.p12` imported via CLI lacks the Apple partition list → `codesign` prompts on every call; remedy: `security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db` (once).
6. **[release.yml](../../.github/workflows/release.yml)**: after signing the app — zip `ditto -c -k --sequesterRsrc --keepParent`, notarize the zip, staple the app, re-zip, then existing DMG flow unchanged; `generate_appcast` step: download the previous release's appcast into a folder with only the new zip + `SpaceMatters-X.Y.Z.md` (body of `gh release view --json body`), run with `echo "$SPARKLE_ED_PRIVATE_KEY" | generate_appcast --ed-key-file - --download-url-prefix "https://github.com/Evariops/SpaceMatters/releases/download/vX.Y.Z/" --embed-release-notes` — the accumulation and preservation of old URLs are proven (§6.1); keep `--maximum-versions` at default (3); upload the zip + `appcast.xml` as release assets. Mirror in `release.sh` for local releases.
7. **README**: transparency paragraph (what the update check does, how to turn it off) + track A first-install walkthrough (Settings ▸ "Open anyway"), honest and illustrated.

## 5. Verification

- **Full cycle locally**: serve a forged appcast on `http://localhost:8000` (`python3 -m http.server`, dev `SUFeedURL` in a test bundle), install an aged build → detection, markdown notes rendered, install, relaunch in higher version.
- **Quarantine**: after a real update, `xattr -lr /Applications/SpaceMatters.app` shows no `com.apple.quarantine`; the app relaunches without a Gatekeeper dialog.
- **FDA**: ✅ **validated live on 2026-07-12**. Two builds (v0.0.1 and v9.9.9) signed with the stable "SpaceMatters" cert → **identical designated requirement** (`identifier "com.spacematters.app" and certificate leaf = H"6ec027a9…"`), deterministic proof that TCC treats them as the same client. End-to-end: FDA granted to v0.0.1 from `~/Applications`, Sparkle update → v9.9.9, **the grant persisted without a new authorization**. This was THE unproven link of track A; now it is proven.
- **Signature**: `codesign --verify --strict --verbose=2` on the updated app. Track B only: `spctl -a -vv` (fails by construction on track A, non-notarized) and hardened runtime on all Mach-O files (the safeguard is notarization).
- **First install track A**: DMG downloaded on a clean session → observe and document the exact macOS 15 "Open anyway" walkthrough for the README.
- **Appcast**: `curl -L …/releases/latest/download/appcast.xml` → valid XML, accumulated entries, `sparkle:version` = commit count increasing between two releases.
- **Real end-to-end test**: machine with vN-1 installed from the public DMG → publish vN → the update arrives, installs, release notes conform to the release-drafter draft.

## 6. Acquired certainties & residual risks

All 🔬 assumptions from the first draft were lifted on **2026-07-12**, by three means: real experimentation on this machine (Sparkle 2.9.4 added to the project, built, tested; `generate_appcast`/`sign_update` tools run on simulated releases; framework embedded, signed and launched), reading the Sparkle source cloned at tag 2.9.4, and queries against the real GitHub repo. `Package.swift` was restored after the experiment — none of this is committed.

### 6.1 Proven by experiment

- ✅ **XCFramework + SwiftPM: zero friction.** Dependency added to `Package.swift`: `swift build` OK, **`swift test`: 102 tests, 15 suites, all green, with no configuration whatsoever**. SwiftPM copies `Sparkle.framework` next to the build binary and lays down a `@loader_path` rpath — the raw binary (`--volumes`) also runs. The "rpath to set for tests" assumption was unfounded. Framework: 3.0 MB of which 424 KB of XPC services; tools in `.build/artifacts/sparkle/Sparkle/bin/`.
- ✅ **Appcast accumulation in CI.** Full simulation of two successive releases (archives fabricated, real `generate_appcast`) in the exact CI scenario — previous appcast + only the new archive: the old entry is **preserved identically** (URL prefixed `v0.1.0` and `sparkle:edSignature` intact despite `--download-url-prefix …/v0.2.0/`), the new one is added with its own URL. `--maximum-versions` (default 3) bounds the accumulation.
- ✅ **Markdown notes embedded without post-processing.** `.md` file adjacent to the archive + `--embed-release-notes` → `<description sparkle:format="markdown">` in CDATA, UTF-8 content as-is (observed in the generated appcast).
- ✅ **Explicit inner→outer signature.** Framework actually embedded in a SpaceMatters bundle (XPC removed), signed `Autoupdate` → `Updater.app` → framework → app: `codesign --verify --strict --verbose=2` passes, designated requirement satisfied.
- ✅ **Dev pitfall identified and remedy proven.** Ad-hoc + `--options runtime`: `codesign` succeeds **but dyld kills the app at launch** — `mapping process and mapped file (non-platform) have different Team IDs` (hardened runtime library validation). Re-signed ad-hoc **without** runtime: the app loads the embedded framework and runs. Hence the firm instruction in §4.2 for `bundle.sh`. In CI, Developer ID gives the same Team ID to the app and to the re-signed framework → the constraint is satisfied by construction.
- ✅ **`generate_appcast` safeguards.** The tool **refuses** an archive whose app is not validly Apple-signed ("failed Apple Code Signing checks", observed on an unsigned app), and emits a `sparkle:edSignature` only if the archived app declares a `SUPublicEDKey` matching the private key provided (observed: without the key in the plist, appcast generated without signature). CI therefore cannot accidentally publish an unsigned update or one signed with the wrong key — but this imposes the order in §4: key in the plist **before** the first Sparkle release.
- ✅ **CI key format.** `--ed-key-file -` accepts the seed format (base64 of 32 bytes) on stdin — tested with `sign_update` and `generate_appcast` (signature emitted and consistent between the two tools).
- ✅ **Stable `latest/download` URL.** `releases/latest/download/SpaceMatters-0.3.0.dmg` on the real repo: 302 followed → 200 on the GitHub CDN. Sparkle (NSURLSession) follows redirects.

### 6.2 Proven by the Sparkle 2.9.4 source

- ✅ **Quarantine lifting**: first step of the installation — `SUPlainInstaller.m:50` calls `releaseItemFromQuarantineAtRootURL`; implementation `SUFileManager.m:120`: **recursive** removal of the `com.apple.quarantine` xattr (non-fatal failure, logged). No dependency on the sandbox or the hardened runtime. The `xattr` test in §5 remains as end-to-end confirmation, not as an assumption.
- ✅ **Double validation of updates**: `SUUpdateValidator.m:162` — for an app bundle, EdDSA **and** the Apple signature are verified; the "code signing only" fallback only exists if EdDSA fails and then requires the **same Developer ID Team ID as the installed app** (`codeSignatureIsValidAtDownloadURL:andMatchesDeveloperIDTeamFromOldBundleURL:`, `SUUpdateValidator.m:84`).
- ✅ **Markdown**: `SUAppcastItem.m:533` accepts `sparkle:format` ∈ {plain-text, markdown, html} (default html); `SUUpdateAlert.m:189` routes markdown to `SUTextViewReleaseNotesView` (native `NSAttributedString` rendering, macOS 12+ API — we target 15). Lists, links, emphasis, code: yes; GFM tables and raw HTML: no. Compatible with release-drafter (lists with links).
- ✅ **XPC services opt-in**: `SPUXPCServiceInfo.m` — used only if the host app declares `SUEnableInstallerLauncherService`/`SUEnableDownloaderService`/… in its plist. Absent in our case → removal of `XPCServices/` (424 KB) with no functional effect whatsoever.
- ✅ **Consent before any network**: `SPUUpdater.m:415` — the authorization prompt waits for the **second launch** (`SUPromptUserOnFirstLaunchKey` to force it on the first) and no automatic check leaves before agreement. Conforms to the no-phone-home ethos.

### 6.3 Residual risks (real, assumed)

- **Track A — one remaining link at the first CI run**: `codesign` with the self-signed cert imported into the CI's ephemeral keychain (the workflow's `.p12` import is battle-tested for Developer ID; a self-signed cert may require a trust setting — to be observed). FDA persistence, for its part, is **proven** live (§5).
- **Track B (when the day comes)**: the `notarytool` pass on the app with Sparkle embedded will only be proven at the first CI run with the Apple secrets. High confidence (hardened runtime everywhere, same Team ID); and the switch costs a one-time FDA re-grant per user (§3.7).
- **On-screen appearance of the notes**: the supported markdown subset is known (source read), but the visual rendering is judged in live driving (§5) — `releaseNotesLink` fallback ready.
- **Loss of the EdDSA key** (operational, permanent): public key baked into every installed app → the §4.4 vault backup is not optional.
- **Weight** (measured on the real release app, `ditto` zips): installed app 4.5 MB → 6.9 MB (**+2.4 MB**, universal framework without XPC/headers); download 1.4 MB → 2.3 MB (**+0.9 MB**). With `lipo -thin arm64` (consistent: the app is arm64-only): installed **+1.4 MB**, downloaded **+0.5 MB**. Accepted — it's the price of the hardened installer.
- External prerequisite unchanged since SPEC-07: Developer ID secrets + notarization configured in the repo so the CI flow actually signs.

## 7. Effort & dependencies

**1–2 days** (integration + CI + real tests on two releases). Depends on SPEC-07 (✅ delivered) and the CI signing secrets (external prerequisite). Independent of the rest.
