# SPEC-12 — Mises à jour automatiques : Sparkle 2

> **Contexte** : SPEC-07 a livré la distribution v1 (DMG signé Developer ID + notarisé + stapled via GitHub Releases) et listait explicitement l'auto-update comme hors périmètre (§4). Cette spec ferme ce chantier.
> **Périmètre v1** : check automatique consenti + « Check for Updates… » manuel, update in-place depuis GitHub Releases, release notes affichées. Canal beta, deltas et pane Settings repoussés (§3.8).
> **Contrainte produit (2026-07-12)** : pas de compte Apple Developer pour l'instant, décision repoussée au maximum **sans fermer la porte** — d'où la stratégie d'identité en deux pistes du §3.7 : auto-signée stable aujourd'hui, bascule Developer ID par simple ajout de secrets, transition transparente pour les updates (chaîne EdDSA).
> **Statut** : 🚧 **implémenté le 2026-07-12** (branche `feat/spec12-sparkle-updates`, non poussée) — jalons §4.1–4.7 faits, bundle vérifié (signature stricte, lancement, DR stable). Toutes les hypothèses 🔬 levées le même jour par expérimentation réelle (§6). **Reste** : cycle d'update live (§5), test FDA piste A, première release réelle.

## 1. Objectif

L'utilisateur qui a installé SpaceMatters depuis le DMG est prévenu qu'une nouvelle version existe, lit les notes de version, clique « Install » — l'app se remplace en place, relance, **sans re-passage Gatekeeper et sans perdre le grant Full Disk Access**. Le tout sans qu'aucune connexion réseau ne parte avant son consentement explicite.

Framework retenu : **[Sparkle 2](https://github.com/sparkle-project/Sparkle)** (2.9.4 au moment de la rédaction). Licence **MIT** (+ BSD 2-clause pour bsdiff/bspatch, MIT pour ed25519 — vérifié sur la branche 2.x) : compatible Apache 2.0, aucune obligation au-delà de la conservation des mentions de copyright.

## 2. État actuel du code (vérifié)

- **Chaîne de release complète et fonctionnelle** (SPEC-07) : [release.sh](../Packaging/release.sh) en local, [release.yml](../.github/workflows/release.yml) en CI (déclenché à la publication du draft) — build → `bundle.sh` → sign hardened-runtime → DMG → notarize → staple → upload asset. Trois releases taguées (v0.1.0 → v0.3.0).
- **Release notes déjà produites** : [release-drafter.yml](../.github/workflows/release-drafter.yml) maintient un draft en markdown, catégorisé par labels de PR — la matière première des notes d'update existe déjà, il faut juste la faire transiter vers l'appcast.
- **Versionnage compatible Sparkle tel quel** : `CFBundleShortVersionString` = tag semver ([Packaging/bundle.sh:49](../Packaging/bundle.sh#L49)), `CFBundleVersion` = **nombre de commits** ([Packaging/bundle.sh:32](../Packaging/bundle.sh#L32), `fetch-depth: 0` en CI pour ça, [release.yml:45](../.github/workflows/release.yml#L45)) — entier, strictement croissant sur `main` : directement utilisable comme `sparkle:version`.
- **Bundle artisanal, binaire statique unique** : `bundle.sh` génère l'Info.plist par heredoc ([Packaging/bundle.sh:39-64](../Packaging/bundle.sh#L39-L64)), aucun `Contents/Frameworks`, aucun rpath. Signature actuelle en `codesign --deep` ([Packaging/bundle.sh:75](../Packaging/bundle.sh#L75), [Packaging/release.sh](../Packaging/release.sh#L36)) — devra devenir explicite (inner→outer) avec un framework embarqué.
- **Pas de sandbox, pas d'entitlements** (vérifié : aucun `.entitlements`, aucun `com.apple.security.*`) : les XPC services de Sparkle sont inutiles ici, intégration simplifiée.
- **Aucun code réseau dans l'app** : zéro `URLSession` dans `Sources/`. Sparkle sera la **première connexion sortante** de l'app — l'ethos maison est explicite ([NativeCleaner.swift:53](../Sources/SpaceMatters/Scanner/NativeCleaner.swift#L53) : « a cleaner must not update taps or phone home »), donc consentement d'abord, transparence README ensuite.
- **Points d'ancrage UI** : entry point GUI [SpaceMattersApp.swift:40-56](../Sources/SpaceMatters/App/SpaceMattersApp.swift#L40-L56) (attention : l'enum `Entry` `@main` route aussi des sous-commandes CLI headless — l'updater ne doit vivre que dans le chemin GUI) ; un seul bloc `.commands` ([SpaceMattersApp.swift:49-55](../Sources/SpaceMatters/App/SpaceMattersApp.swift#L49-L55)) ; pas de scène Settings (réglages ad-hoc via `@AppStorage`).
- **FDA keyé sur la signature** : la designated requirement Developer ID est stable → le grant TCC survit à un remplacement du bundle par Sparkle (même identité, même bundle id). C'est précisément le scénario que la signature stable de SPEC-07 rend possible.

## 3. Axes de conception & tradeoffs

### 3.1 Sparkle vs « check maison » GitHub API

Un check maison (interroger `releases/latest`, proposer le téléchargement) éviterait la dépendance — mais tout ce qui a de la valeur est dans l'install : remplacement atomique du bundle, validation de signature, **levée de quarantaine**, relance propre. Réimplémenter ça, c'est réécrire le code le plus sensible de Sparkle sans ses dix ans de durcissement. Sparkle est le standard de facto hors App Store (iTerm2, Transmit…), sa licence est triviale, et il se consomme en dépendance SPM (XCFramework binaire). **Décision : Sparkle 2.**

### 3.2 Livrable d'update : un zip dédié, le DMG reste pour l'humain

Le DMG (fond stylisé, drag-to-Applications) reste le canal du **premier** téléchargement. Pour l'appcast, on publie en plus un **zip** créé par `ditto -c -k --sequesterRsrc --keepParent` (préservation des symlinks, exigée par la doc Sparkle pour ne pas casser la signature). Sparkle sait consommer un DMG, mais le zip est plus rapide à extraire, et c'est le format d'entrée des deltas `generate_appcast` si on les active plus tard.

### 3.3 Hébergement de l'appcast

| Option | Pour | Contre |
|---|---|---|
| **A. Asset de release, URL `releases/latest/download/appcast.xml`** ✅ | Zéro infra, même pipeline que le DMG, URL stable (redirection 302 suivie par Sparkle) | Retirer une release fautive = ré-uploader l'asset ; `latest` ignore les prereleases (à revisiter pour un canal beta) |
| B. Branche `gh-pages` + GitHub Pages | Feed indépendant des releases, patchable sans re-release | Une branche et un déploiement Pages à maintenir pour un fichier |
| C. Commit sur `main`, servi par raw.githubusercontent | — | CI qui pushe sur `main` : non |

**Décision : A.** `SUFeedURL = https://github.com/Evariops/SpaceMatters/releases/latest/download/appcast.xml`. `generate_appcast` préserve les entrées d'un appcast existant : le CI télécharge l'appcast de la release précédente, ajoute la nouvelle entrée, ré-uploade le cumul — les anciennes URLs absolues (par tag) restent valides.

### 3.4 Chaîne de confiance, quarantaine, notarisation

- **EdDSA** : `generate_keys` (une fois, en local) → clé publique dans le plist (`SUPublicEDKey`), clé privée exportée (`generate_keys -x`) vers un secret GitHub `SPARKLE_ED_PRIVATE_KEY` (lu par `generate_appcast --ed-key-file -` sur stdin) **et sauvegardée hors GitHub** (trousseau + coffre) : la clé publique étant gravée dans toutes les apps installées, sa perte rend les clients existants incapables d'updater.
- Sparkle vérifie **EdDSA + la signature Apple** (l'update doit être signée par la même équipe que l'app en place) : même un compte GitHub compromis ne peut pas pousser une update acceptée sans la clé privée EdDSA.
- **Quarantaine** : le zip téléchargé par Sparkle reçoit `com.apple.quarantine` comme tout téléchargement ; Sparkle valide lui-même les deux signatures puis **retire l'attribut à l'installation** — l'app updatée relance sans re-passage Gatekeeper ni app translocation. C'est le mécanisme central que le check maison n'aurait pas.
- **Notarisation du zip quand même** *(piste B uniquement — sans compte Apple ce point tombe, et Sparkle n'en a pas besoin)* : le flux Sparkle ne l'exige pas (quarantaine levée), mais le même zip est téléchargeable à la main depuis la page Release. On notarise donc **l'app avant zippage** : `ditto` → `notarytool submit` du zip → `stapler staple` sur le `.app` → re-`ditto` du zip final → le DMG est ensuite construit à partir de l'app stapled (le flux DMG existant ne change pas, sa soumission devient quasi instantanée, contenu déjà ticketé).

### 3.5 Release notes : le draft release-drafter, rendu par Sparkle

Sparkle 2.9+ rend le **markdown** nativement (`<description sparkle:format="markdown">`). Aucun post-traitement à écrire : `generate_appcast` consomme un fichier **`.md` adjacent à l'archive** (même nom de base : `SpaceMatters-X.Y.Z.md`) et, avec `--embed-release-notes`, l'embarque tel quel en `<description sparkle:format="markdown">` — **vérifié en exécutant l'outil** (§6.1). Le CI écrit ce fichier depuis `gh release view --json body`. Contrainte de rendu (source lue, §6.2) : c'est un rendu texte natif `NSAttributedString`, pas WKWebView — listes, liens et emphase passent ; tableaux et HTML brut non. Release-drafter ne produit que des listes à liens → compatible. Repli si le rendu déçoit visuellement : `<sparkle:releaseNotesLink>` vers la page GitHub de la release.

### 3.6 UX : consentement d'abord

- **Instanciation** : `SPUStandardUpdaterController(startingUpdater: true, …)` détenu par `SpaceMattersApp` (chemin GUI uniquement — jamais dans les sous-commandes CLI de `Entry`).
- **Menu** : « Check for Updates… » via `CommandGroup(after: .appInfo)` dans le bloc `.commands` existant, activé/désactivé par `updater.publisher(for: \.canCheckForUpdates)` (petit `UpdaterModel` observable).
- **Check automatique** : on garde le comportement standard Sparkle — **prompt de consentement au second lancement**, aucun check avant accord. `SUEnableAutomaticChecks` volontairement absent du plist (le forcer court-circuiterait le prompt). Aligné avec l'ethos no-phone-home ; le README documente ce que fait le check (requête de l'appcast, pas de télémétrie).
- Pas de scène Settings en v1 : le prompt Sparkle + le menu suffisent ; un toggle dans une future scène Settings (`automaticallyChecksForUpdates`) viendra avec d'autres réglages.

### 3.7 Identité de signature : auto-signée d'abord, Developer ID quand on voudra

Décision produit : repousser le compte Apple Developer (99 $/an) au maximum, sans se fermer la porte. Deux pistes, **même architecture** — la chaîne de confiance des updates est EdDSA dans les deux cas, l'identité Apple n'est qu'un paramètre :

**Piste A — maintenant, gratuite : certificat auto-signé stable.**
- Créer un certificat de code signing auto-signé « SpaceMatters » (Trousseau ▸ Assistant de certification, celui que [Packaging/bundle.sh:68-71](../Packaging/bundle.sh#L68-L71) documente déjà) — **validité longue (3650 jours)**, pas les 365 par défaut : à l'expiration, changer de certificat = nouvelle designated requirement = FDA re-demandé.
- L'exporter en `.p12` → secrets repo `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` (les **mêmes noms** que pour Developer ID : la piste B consistera littéralement à remplacer le contenu du secret).
- Signature **sans hardened runtime** (prouvé §6.1 : sans Team ID, la library validation tue l'app au lancement) ; pas de notarisation (impossible sans compte, et inutile : Sparkle lève la quarantaine des updates lui-même, §6.2).
- Ce que ça garantit : designated requirement stable (le cert est embarqué dans la signature) → **FDA persiste à travers les updates** ; identité acceptée par `generate_appcast` (l'ad-hoc passe, prouvé §6.1) et par la validation Sparkle côté client.
- Ce que ça coûte : premier install hostile sur macOS 15 (plus de clic-droit ▸ Ouvrir : Réglages ▸ Confidentialité ▸ « Ouvrir quand même »), à documenter honnêtement dans le README. Une fois installée, plus aucun passage Gatekeeper.

**Piste B — plus tard, 99 $/an : Developer ID + notarisation.**
- Remplacer le `.p12` des secrets par le certificat Developer ID et ajouter `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_SPECIFIC_PASSWORD` — le workflow est déjà conditionnel (`HAS_SIGNING`/`HAS_NOTARY`), la notarisation s'active seule.
- Réactiver `--options runtime` (conditionné dans les scripts : hardened runtime **si et seulement si** l'identité est « Developer ID Application: * »).

**La transition A→B est sûre pour le parc installé** (source lue, §6.2) : le contrôle « même Team ID que l'app en place » de `SUUpdateValidator.m:84` n'existe que dans le chemin de repli *sans* EdDSA ; sur le chemin nominal, une app auto-signée accepte une update signée Developer ID dès lors que l'EdDSA est valide — et notre clé EdDSA ne change pas. Coût unique de la bascule : la designated requirement change → **FDA re-demandé une fois** par utilisateur ; à mentionner dans les notes de la release de transition.

À adapter dans [release.yml](../.github/workflows/release.yml) : l'extraction d'identité ([release.yml:67-68](../.github/workflows/release.yml#L67-L68)) ne matche que `Developer ID Application:` **et** utilise `find-identity -v`, qui masque un cert auto-signé non trusté (constaté le 2026-07-12 : l'identité SpaceMatters apparaît `CSSMERR_TP_NOT_TRUSTED` sans `-v`, invisible avec, alors que `codesign` signe parfaitement avec). → dropper le `-v`, matcher toute identité de code signing, et conditionner `--options runtime` + notarisation au motif `Developer ID Application:`.

### 3.8 Hors périmètre v1

- **Deltas binaires** : `generate_appcast` les produit gratuitement si on lui fournit les N zips précédents — à activer quand l'app grossira (aujourd'hui quelques Mo, gain marginal).
- **Canal beta** (`sparkle:channel`) — exigera de revisiter l'option A de §3.3 (`latest` ignore les prereleases).
- **Cask Homebrew** (`auto_updates true` une fois Sparkle en place).

## 4. Plan d'implémentation

1. **[Package.swift](../Package.swift)** : dépendance `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")`, produit `Sparkle` sur la cible exécutable, rpath `@executable_path/../Frameworks` via `linkerSettings` (le target utilise déjà `unsafeFlags`, pas de contrainte nouvelle). Dev et tests ne demandent **aucun autre réglage** : SwiftPM copie le framework à côté du binaire de build et pose un rpath `@loader_path` (vérifié §6.1).
2. **[Packaging/bundle.sh](../Packaging/bundle.sh)** : entre la copie du binaire et la signature — créer `Contents/Frameworks/`, y copier `Sparkle.framework` depuis `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/` (chemin constaté), **supprimer `Versions/B/XPCServices/`** (424 Ko, inutiles hors sandbox — §6.2) ainsi que `Headers/`, `PrivateHeaders/` et `Modules/` (224 Ko, inutiles à l'exécution) ; optionnel : `lipo -thin arm64` sur les trois Mach-O du framework (l'app est déjà distribuée arm64-only — `swift build` natif, runner CI arm64), gain ≈ 1 Mo installé / 0,4 Mo téléchargé ; ajouter `SUFeedURL` et `SUPublicEDKey` au heredoc du plist (**obligatoire avant de builder une release : sans `SUPublicEDKey` dans l'app archivée, `generate_appcast` n'émet pas de signature** — §6.1) ; remplacer le `codesign --deep` par une signature explicite inner→outer (`Autoupdate`, `Updater.app`, le framework, puis l'app) — même chose dans [Packaging/release.sh](../Packaging/release.sh#L36). ⚠️ **`--options runtime` seulement si l'identité est Developer ID** (piste B) : sans Team ID — ad-hoc dev comme certificat auto-signé de la piste A — la library validation tue l'app au lancement (`different Team IDs`, prouvé §6.1).
3. **Code Swift** : `UpdaterModel` (wrapping `SPUStandardUpdaterController` + `canCheckForUpdates` publié), instancié dans `SpaceMattersApp`, item de menu dans `.commands`.
4. **Clés** : ✅ **fait le 2026-07-12** — paire EdDSA générée (`generate_keys`) : privée dans le trousseau de session (item « Private key for signing Sparkle updates ») **et** secret repo `SPARKLE_ED_PRIVATE_KEY` ; publique à graver dans le heredoc de `bundle.sh` :
   ```xml
   <key>SUPublicEDKey</key>    <string>giAqx0Y+CIUuSvv4DDNfJnC/wF16Y71qi03XF3LZx30=</string>
   ```
   ✅ Sauvegarde coffre faite (2026-07-12). La clé privée existe en trois exemplaires : trousseau de session, secret repo, coffre.
5. **Certificat auto-signé (piste A, §3.7)** : ✅ **créé le 2026-07-12** (openssl : CN=SpaceMatters, RSA 2048, EKU code-signing critique, **valide jusqu'au 2036-07-09**), importé dans le trousseau de session, signature testée (`Authority=SpaceMatters`, designated requirement épinglée `certificate leaf = H"6ec027a9795823a6b14b4c84d209f2ebf16fe27f"`). `.p12` + mot de passe dans `~/Documents/SpaceMatters-signing-backup/` — **à mettre au coffre puis supprimer du disque** (cert perdu = FDA re-demandé chez tous les utilisateurs). ✅ Secrets repo `MACOS_CERT_P12` + `MACOS_CERT_PASSWORD` posés (2026-07-12) — l'inventaire piste A est complet avec `SPARKLE_ED_PRIVATE_KEY`. ✅ Extraction d'identité élargie (sans `-v`) et runtime/notarisation conditionnés au type d'identité dans `release.yml`.
   > **Implémentation (2026-07-12)** : jalons 1–7 réalisés sur `feat/spec12-sparkle-updates` — scripts déménagés dans `Packaging/` (+ `make-appcast.sh` partagé CI/local), 102 tests verts, bundle release signé `SpaceMatters` vérifié strict + lancé, appcast CI câblé. Piège trousseau relevé au passage : un `.p12` importé en CLI n'a pas la partition list Apple → `codesign` prompte à chaque appel ; remède : `security set-key-partition-list -S apple-tool:,apple: -s ~/Library/Keychains/login.keychain-db` (une fois).
6. **[release.yml](../.github/workflows/release.yml)** : après la signature de l'app — zip `ditto -c -k --sequesterRsrc --keepParent`, notarisation du zip, staple de l'app, re-zip, puis flux DMG existant inchangé ; étape `generate_appcast` : télécharger l'appcast de la release précédente dans un dossier avec le seul nouveau zip + `SpaceMatters-X.Y.Z.md` (corps de `gh release view --json body`), lancer avec `echo "$SPARKLE_ED_PRIVATE_KEY" | generate_appcast --ed-key-file - --download-url-prefix "https://github.com/Evariops/SpaceMatters/releases/download/vX.Y.Z/" --embed-release-notes` — le cumul et la préservation des anciennes URLs sont prouvés (§6.1) ; garde `--maximum-versions` par défaut (3) ; upload du zip + `appcast.xml` en assets de release. Miroir dans `release.sh` pour les releases locales.
7. **README** : paragraphe transparence (ce que fait le check d'update, comment le couper) + parcours premier install piste A (Réglages ▸ « Ouvrir quand même »), honnête et illustré.

## 5. Vérification

- **Cycle complet en local** : servir un appcast forgé sur `http://localhost:8000` (`python3 -m http.server`, `SUFeedURL` de dev dans un bundle de test), installer un build vieilli → détection, notes markdown rendues, install, relance en version supérieure.
- **Quarantaine** : après une vraie update, `xattr -lr /Applications/SpaceMatters.app` ne montre aucun `com.apple.quarantine` ; l'app relance sans dialogue Gatekeeper.
- **FDA** : granter Full Disk Access sur vN, updater vers vN+1 via Sparkle → le grant persiste (pilotage live : l'app scanne sans bandeau FDA). **C'est LE test de validation de la piste A** (designated requirement stable du cert auto-signé) — à faire avant la première release publique piste A ; simulable sans release : granter FDA, re-signer un build différent avec le même cert, relancer, vérifier le grant.
- **Signature** : `codesign --verify --strict --verbose=2` sur l'app updatée. Piste B uniquement : `spctl -a -vv` (échoue par construction en piste A, non notarisée) et hardened runtime sur tous les Mach-O (le garde-fou est la notarisation).
- **Premier install piste A** : DMG téléchargé sur une session vierge → constater et documenter le parcours exact « Ouvrir quand même » de macOS 15 pour le README.
- **Appcast** : `curl -L …/releases/latest/download/appcast.xml` → XML valide, entrées cumulées, `sparkle:version` = commit count croissant entre deux releases.
- **Test réel de bout en bout** : machine avec vN-1 installée depuis le DMG public → publier vN → l'update arrive, s'installe, release notes conformes au draft release-drafter.

## 6. Certitudes acquises & risques résiduels

Toutes les hypothèses 🔬 de la première rédaction ont été levées le **2026-07-12**, par trois moyens : expérimentation réelle sur cette machine (Sparkle 2.9.4 ajouté au projet, buildé, testé ; outils `generate_appcast`/`sign_update` exécutés sur des releases simulées ; framework embarqué, signé et lancé), lecture de la source Sparkle clonée au tag 2.9.4, et requêtes sur le repo GitHub réel. `Package.swift` a été restauré après l'expérience — rien de tout ceci n'est commité.

### 6.1 Prouvé par l'expérience

- ✅ **XCFramework + SwiftPM : zéro friction.** Dépendance ajoutée à `Package.swift` : `swift build` OK, **`swift test` : 102 tests, 15 suites, tous verts, sans aucune configuration**. SwiftPM copie `Sparkle.framework` à côté du binaire de build et pose un rpath `@loader_path` — le binaire brut (`--volumes`) tourne aussi. L'hypothèse « rpath à régler pour les tests » était infondée. Framework : 3,0 Mo dont 424 Ko de XPC services ; outils dans `.build/artifacts/sparkle/Sparkle/bin/`.
- ✅ **Cumul d'appcast en CI.** Simulation complète de deux releases successives (archives fabriquées, `generate_appcast` réel) dans le scénario CI exact — appcast précédent + seule la nouvelle archive : l'entrée ancienne est **préservée à l'identique** (URL préfixée `v0.1.0` et `sparkle:edSignature` intactes malgré `--download-url-prefix …/v0.2.0/`), la nouvelle s'ajoute avec sa propre URL. `--maximum-versions` (défaut 3) borne le cumul.
- ✅ **Notes markdown embarquées sans post-traitement.** Fichier `.md` adjacent à l'archive + `--embed-release-notes` → `<description sparkle:format="markdown">` en CDATA, contenu UTF-8 tel quel (constaté dans l'appcast généré).
- ✅ **Signature explicite inner→outer.** Framework réellement embarqué dans un bundle SpaceMatters (XPC supprimés), signé `Autoupdate` → `Updater.app` → framework → app : `codesign --verify --strict --verbose=2` passe, designated requirement satisfaite.
- ✅ **Piège dev identifié et remède prouvé.** Ad-hoc + `--options runtime` : `codesign` réussit **mais dyld tue l'app au lancement** — `mapping process and mapped file (non-platform) have different Team IDs` (library validation du hardened runtime). Re-signé ad-hoc **sans** runtime : l'app charge le framework embarqué et tourne. D'où la consigne ferme du §4.2 pour `bundle.sh`. En CI, Developer ID donne le même Team ID à l'app et au framework re-signé → la contrainte est satisfaite par construction.
- ✅ **Garde-fous de `generate_appcast`.** L'outil **refuse** une archive dont l'app n'est pas signée Apple valide (« failed Apple Code Signing checks », constaté sur une app non signée), et n'émet de `sparkle:edSignature` que si l'app archivée déclare `SUPublicEDKey` correspondant à la clé privée fournie (constaté : sans la clé dans le plist, appcast généré sans signature). Le CI ne peut donc pas publier par accident une update non signée ou signée avec la mauvaise clé — mais ça impose l'ordre du §4 : clé dans le plist **avant** la première release Sparkle.
- ✅ **Format de clé CI.** `--ed-key-file -` accepte le format seed (base64 de 32 octets) sur stdin — testé avec `sign_update` et `generate_appcast` (signature émise et cohérente entre les deux outils).
- ✅ **URL stable `latest/download`.** `releases/latest/download/SpaceMatters-0.3.0.dmg` sur le repo réel : 302 suivi → 200 sur le CDN GitHub. Sparkle (NSURLSession) suit les redirections.

### 6.2 Prouvé par la source Sparkle 2.9.4

- ✅ **Levée de quarantaine** : première étape de l'installation — `SUPlainInstaller.m:50` appelle `releaseItemFromQuarantineAtRootURL` ; implémentation `SUFileManager.m:120` : suppression **récursive** de l'xattr `com.apple.quarantine` (échec non fatal, loggé). Aucune dépendance au sandbox ni au hardened runtime. Le test `xattr` de §5 reste comme confirmation de bout en bout, pas comme hypothèse.
- ✅ **Double validation des updates** : `SUUpdateValidator.m:162` — pour un bundle d'app, EdDSA **et** signature Apple sont vérifiées ; le repli « code signing seul » n'existe que si l'EdDSA échoue et exige alors le **même Team ID Developer ID que l'app en place** (`codeSignatureIsValidAtDownloadURL:andMatchesDeveloperIDTeamFromOldBundleURL:`, `SUUpdateValidator.m:84`).
- ✅ **Markdown** : `SUAppcastItem.m:533` accepte `sparkle:format` ∈ {plain-text, markdown, html} (défaut html) ; `SUUpdateAlert.m:189` route markdown vers `SUTextViewReleaseNotesView` (rendu natif `NSAttributedString`, API macOS 12+ — on cible 15). Listes, liens, emphase, code : oui ; tableaux GFM et HTML brut : non. Compatible release-drafter (listes à liens).
- ✅ **XPC services opt-in** : `SPUXPCServiceInfo.m` — utilisés uniquement si l'app hôte déclare `SUEnableInstallerLauncherService`/`SUEnableDownloaderService`/… dans son plist. Absents chez nous → suppression de `XPCServices/` (424 Ko) sans aucun effet fonctionnel.
- ✅ **Consentement avant tout réseau** : `SPUUpdater.m:415` — le prompt d'autorisation attend le **second lancement** (`SUPromptUserOnFirstLaunchKey` pour forcer au premier) et aucun check automatique ne part avant accord. Conforme à l'ethos no-phone-home.

### 6.3 Risques résiduels (réels, assumés)

- **Piste A — deux maillons à prouver au premier run** : (1) `codesign` avec le cert auto-signé importé dans le keychain éphémère du CI (l'import `.p12` du workflow est rodé pour Developer ID ; un cert auto-signé peut exiger un réglage de confiance — à constater) ; (2) la persistance FDA à travers une update auto-signée — test local décrit en §5, à faire **avant** la première release publique.
- **Piste B (le jour venu)** : le passage `notarytool` sur l'app avec Sparkle embarqué ne se prouvera qu'au premier run CI avec les secrets Apple. Confiance haute (hardened runtime partout, même Team ID) ; et la bascule coûte un re-grant FDA unique par utilisateur (§3.7).
- **Apparence des notes à l'écran** : le sous-ensemble markdown supporté est connu (source lue), mais le rendu visuel se juge en pilotage live (§5) — repli `releaseNotesLink` prêt.
- **Perte de la clé EdDSA** (opérationnel, permanent) : clé publique gravée dans toutes les apps installées → la sauvegarde coffre du §4.4 n'est pas optionnelle.
- **Poids** (mesuré sur l'app release réelle, zips `ditto`) : app installée 4,5 Mo → 6,9 Mo (**+2,4 Mo**, framework universel sans XPC/headers) ; téléchargement 1,4 Mo → 2,3 Mo (**+0,9 Mo**). Avec `lipo -thin arm64` (cohérent : l'app est arm64-only) : installé **+1,4 Mo**, téléchargé **+0,5 Mo**. Accepté — c'est le prix de l'installer durci.
- Prérequis externe inchangé depuis SPEC-07 : secrets Developer ID + notarisation configurés dans le repo pour que le flux CI signe réellement.

## 7. Effort & dépendances

**1–2 jours** (intégration + CI + tests réels sur deux releases). Dépend de SPEC-07 (✅ livré) et des secrets de signature CI (prérequis externe). Indépendant du reste.
