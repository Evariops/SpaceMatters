# SPEC-07 — Distribution : icône, notarisation, About, mises à jour

> **Findings** : J1.1 (pas de binaire de release), J1.2 (icône générique), J1.4 (usage descriptions TCC absentes), J1.5 (version/About), D4 (signature/notarisation). I3 (`bundle.sh` `|| true`) **déjà corrigé**.

## 1. Objectif

Rendre l'app **partageable** (« le collègue dont le disque est plein ») : signée Developer ID + notarisée, avec icône, About/version, prompts TCC explicites, et un canal de distribution.

## 2. État actuel (vérifié)

- `bundle.sh` : signature ad-hoc (cdhash instable → FDA à re-granter), pas de notarisation, aucun `CFBundleIconFile`/`.icns`, `CFBundleShortVersionString` figé « 1.0 », bundle id `com.macdirstats.app`. Échec total de `codesign` **désormais non masqué** (I3 fait).
- Aucune clé `NS*UsageDescription` → prompts TCC nus (J1.4).
- Détection FDA via ouverture de `TCC.db` ([FullDiskAccess.swift](../Sources/MacDirStats/Util/FullDiskAccess.swift)) — bien documentée.

## 3. Plan d'implémentation

1. **Icône** : `AppIcon.icns` (le camembert du splash suffit) + `CFBundleIconFile` dans `bundle.sh` (J1.2).
2. **Usage descriptions** : ajouter `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` au plist généré (J1.4) — phrases explicites.
3. **Signature Developer ID + notarisation** : `codesign --options runtime` avec identité Developer ID, `xcrun notarytool submit --wait`, `xcrun stapler staple` ; DMG signé/notarisé (J1.1, D4).
4. **About + version** : panneau About custom ; `CFBundleShortVersionString`/`CFBundleVersion` **dérivés de git** (`git describe`) au build (J1.5).
5. **Mises à jour** : Sparkle *ou* un simple « check GitHub releases ». Cask Homebrew pour l'install (`brew install --cask macdirstats`).
6. **Onboarding FDA** (J1.3) : bandeau avec mini-étapes (« ajoutez l'app avec **+** puis relancez »), limité à la route filesystem, re-proposé quand `errorCount` explose sans FDA.

## 4. Vérification

- `bundle.sh` produit un `.app` notarisé qui passe Gatekeeper sur une **autre** machine (test manuel).
- `spctl -a -vv MacDirStats.app` → « accepted, source=Notarized Developer ID ».
- Prompts TCC affichent la phrase d'explication.

## 5. Risques & hypothèses

- Nécessite un compte Apple Developer (Developer ID) — prérequis externe.
- 🔬 Hardened runtime vs FDA/debuggabilité : le fallback existant reste utile pour les builds locaux.

## 6. Effort & dépendances

**1–2 jours** (hors obtention du compte Developer). Indépendant.
