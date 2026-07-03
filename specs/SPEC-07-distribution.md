# SPEC-07 — Distribution : DMG signé + notarisé via GitHub

> **Findings** : J1.1 (pas de binaire de release), J1.2 (icône générique), J1.4 (usage descriptions TCC absentes), J1.5 (version/About), D4 (signature/notarisation). I3 (`bundle.sh` `|| true`) **déjà corrigé**.
> **Périmètre v1 (imposé)** : distribuer **uniquement un `.dmg` via GitHub Releases**. Pas de Mac App Store. Cask Homebrew / auto-update repoussés hors v1.
> **Statut** : ✅ **IMPLÉMENTÉ** (tout le codable) — signature/notarisation exécutables une fois le compte Developer ID fourni (prérequis externe).

## 0. Résultat d'implémentation

- **Icône** (J1.2) : [`Scripts/make-icon.sh`](../Scripts/make-icon.sh) rend `chart.pie.fill` (accent sur fond panneau) → `Resources/AppIcon.icns` (généré, commité) ; `bundle.sh` la copie + `CFBundleIconFile`. Vérifié visuellement.
- **Usage descriptions TCC** (J1.4) : `NSDesktop/Documents/Downloads/RemovableVolumes/NetworkVolumes UsageDescription` ajoutées au plist. `plutil -lint` OK.
- **Version depuis git** (J1.5) : `CFBundleShortVersionString` = `git describe --tags` (repli `0.1.0`), `CFBundleVersion` = nb de commits. Vérifié (`0.1.0` / build `26`).
- **`release.sh`** : build → `bundle.sh` (Developer ID) → **hardened-runtime sign + verify** → DMG (`hdiutil`, app + alias `/Applications`) → sign DMG → `notarytool submit --wait` → `stapler staple` → `spctl` check → **`gh release create`**. Prérequis externes documentés en tête (cert Developer ID + profil `notarytool` + `gh auth`).
- **README** : section « Download » pointant `releases/latest`.
- **`.gitignore`** : `*.dmg` (artefact) exclu ; `MacDirStats.app/` déjà exclu.
- **🔬 Non exécutable ici** : la signature Developer ID + notarisation exigent un compte Apple Developer (prérequis externe assumé par la spec §6). Le repli ad-hoc de `bundle.sh` reste pour le dev local (vérifié : bundle signé ad-hoc lance sans crash).

## 1. Objectif

Un collègue télécharge le `.dmg` depuis la page **GitHub Releases**, le monte, glisse l'app dans Applications, et l'ouvre **sans blocage Gatekeeper** — donc DMG **signé Developer ID + notarisé + stapled**.

## 2. État actuel (vérifié)

- `bundle.sh` : signature **ad-hoc** (cdhash instable → FDA à re-granter), **pas** de notarisation, **aucun** `.icns`/`CFBundleIconFile`, `CFBundleShortVersionString` figé « 1.0 », bundle id `com.macdirstats.app`. Échec total de `codesign` **désormais non masqué** (I3 fait).
- Aucune clé `NS*UsageDescription` → prompts TCC nus (J1.4).
- Détection FDA via ouverture de `TCC.db` ([FullDiskAccess.swift](../Sources/MacDirStats/Util/FullDiskAccess.swift)) — bien documentée ; sensible au cdhash → **la signature stable (Developer ID) fait persister le grant FDA**, gros gain vs ad-hoc.

## 3. Plan d'implémentation (v1)

1. **Icône** (J1.2) : `AppIcon.icns` (le camembert `chart.pie.fill` du splash convient) + `CFBundleIconFile` dans `bundle.sh`.
2. **Usage descriptions TCC** (J1.4) : ajouter au plist généré `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` — phrases explicites.
3. **Version depuis git** (J1.5) : `CFBundleShortVersionString`/`CFBundleVersion` dérivés de `git describe --tags` au build ; petit panneau About custom.
4. **Signature Developer ID + notarisation** :
   - `codesign --force --options runtime --sign "Developer ID Application: …" MacDirStats.app`
   - construire le DMG (`hdiutil create` ou `create-dmg`) avec l'app + alias `/Applications`
   - `codesign` le DMG, `xcrun notarytool submit MacDirStats.dmg --keychain-profile … --wait`, puis `xcrun stapler staple MacDirStats.dmg`.
5. **Script `release.sh`** : build release → bundle → sign → dmg → notarize → staple → `gh release create vX.Y.Z MacDirStats.dmg --notes …`.
6. **README** : section « Download » pointant la dernière Release GitHub.

## 4. Hors périmètre v1 (à garder en tête)

- Cask Homebrew (`brew install --cask macdirstats`) — trivial une fois les Releases en place.
- Auto-update (Sparkle appcast **ou** simple « check GitHub releases »).
- Mac App Store (sandbox incompatible avec le scan disque global — non pertinent).

## 5. Vérification

- `spctl -a -vv -t open --context context:primary-signature MacDirStats.dmg` → « accepted, source=Notarized Developer ID ».
- `codesign -dv --verbose=4 MacDirStats.app` → identité Developer ID, hardened runtime.
- **Test réel** : télécharger le DMG depuis la Release GitHub sur une **autre** session/machine → ouverture sans « développeur non identifié ».
- Vérifier que le grant FDA **persiste** après un rebuild signé (cdhash stable).

## 6. Risques & hypothèses

- Prérequis externe : compte Apple Developer (Developer ID Application) + `notarytool` keychain profile.
- 🔬 Hardened runtime vs debuggabilité locale : garder le fallback ad-hoc de `bundle.sh` pour les builds de dev ; le chemin signé/notarisé est réservé à `release.sh`.

## 7. Effort & dépendances

**1–2 jours** (hors obtention du compte Developer). Indépendant.
