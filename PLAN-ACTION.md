# Plan d'action — MacDirStats

> **Date** : 2026-07-03 · **Sources** : [AUDIT.md](AUDIT.md) (code/algorithmique) + [AUDIT-OPERATIONNEL.md](AUDIT-OPERATIONNEL.md) (expérience quotidienne).
> **Objet** : transformer les ~80 findings des deux audits en un plan séquencé, priorisant l'intégrité, la performance, la robustesse du design, la simplicité et la maintenabilité — **long terme d'abord**, même quand l'effort immédiat est significatif.
>
> **Méthode de ce plan** : chaque finding cité ci-dessous a été **re-vérifié contre le code source réel** dans cette passe (pas seulement relu depuis les audits). La colonne « Vérif. » indique le résultat. Là où une affirmation n'a pas pu être confirmée statiquement (comportement noyau, mesure empirique, fichier non relu), c'est marqué explicitement 🔬 et listé au §8.

---

## Table des matières

- [0. Résultat du triple-check](#0-résultat-du-triple-check)
- [1. Principes directeurs du plan](#1-principes-directeurs-du-plan)
- [2. Décisions d'architecture transverses](#2-décisions-darchitecture-transverses-le-socle) — le socle dont dépendent la plupart des fixes
- [3. Plan par phases](#3-plan-par-phases)
- [4. Détail des chantiers critiques et élevés](#4-détail-des-chantiers-critiques-et-élevés)
- [5. Détail des chantiers moyens](#5-détail-des-chantiers-moyens)
- [6. Détail des chantiers faibles et info](#6-détail-des-chantiers-faibles--info)
- [7. Stratégie de test](#7-stratégie-de-test)
- [8. Ce qui reste à vérifier empiriquement (hypothèses)](#8-ce-qui-reste-à-vérifier-empiriquement)
- [9. Tableau de séquencement récapitulatif](#9-tableau-de-séquencement-récapitulatif)

---

## 0. Résultat du triple-check

**Verdict global** : les deux audits sont d'une qualité élevée. Sur l'ensemble des findings critiques et élevés re-vérifiés dans le code, **aucun n'a été réfuté**. Trois nuances importantes ont émergé et sont intégrées au plan :

1. **A2 (parsing `ATTR_CMN_ERROR`)** — le contrat noyau est **confirmé** (man page `getattrlistbulk` + exemple de référence, voir preuve ci-dessous). Mais la corruption est **bornée à l'entrée fautive** : chaque entrée redémarre à `entry + entryLength` (le champ `entryLength` est toujours lu à l'offset 0), donc les entrées *suivantes* ne sont pas décalées. La formulation « décale tous les offsets » de l'audit vise les offsets *internes à l'entrée*, ce qui est exact. **L'exploitabilité réelle** (crash/OOB vs simple sur-comptage d'erreurs) dépend d'une hypothèse sur le noyau — voir 🔬 au §8.

2. **B1 (use-after-free)** — **confirmé**, scénario tracé pas à pas (voir §4). La chaîne exacte : `reveal(C)` insère les ancêtres `A,B` dans `expanded` (qui les retient) ; `remove(directory: A)` fait `expanded.remove(A)` (seulement `A`, pas la descendance), ne touche **ni** `zoomRoot` **ni** `selection` s'ils sont des *descendants* de `A` → `A` et `B` sont libérés, mais `C` survit (retenu par `zoomRoot`/`selection`) avec un `C.parent (=B)` **pendant**.

3. **A1 (franchissement de montage)** — **mécanisme confirmé** dans le code ([MountInfo.networkMountPoints](Sources/MacDirStats/Scanner/MountInfo.swift#L8) ne renvoie que les montages `!MNT_LOCAL`, donc les montages locaux — VM/Preboot/disques externes/DMG — ne sont jamais dans `skipPaths`). Les **chiffres empiriques** (+850 Ko, 2,38 Mo, etc.) proviennent de l'audit et n'ont pas été re-mesurés ici ; ils sont marqués « à rejouer » (le test est automatisable, cf. §7).

### Preuve A2 (la plus critique) — extraite de la machine cible

`man getattrlistbulk`, section prose :

> « The ATTR_CMN_ERROR attribute is a uint32_t which, if non-zero, specifies the error code that was encountered during the processing of that directory entry. **The ATTR_CMN_ERROR attribute will be after ATTR_CMN_RETURNED_ATTRS attribute in the returned buffer.** »

L'exemple de référence du même man page parse dans cet ordre : `length` → `returned` (attribute_set_t) → **`error` (si bit)** → `name_info` → `obj_type`. C'est une **exception explicite** à la règle générale de `man getattrlist` (« l'ordre suit presque toujours la valeur des bits ») : bien que `ATTR_CMN_ERROR = 0x2000_0000` soit numériquement supérieur à `ATTR_CMN_NAME = 0x1` et `ATTR_CMN_OBJTYPE = 0x8`, l'erreur est packée **avant** eux. Le code actuel ([FSAttr.swift:71-91](Sources/MacDirStats/Scanner/FSAttr.swift#L71-L91)) parse NAME → OBJTYPE → ERROR : **ordre erroné, confirmé**.

### Légende de vérification

| Symbole | Signification |
|---|---|
| ✅ | Confirmé dans le code source dans cette passe |
| ⚠️ | Confirmé mais avec une nuance qui change la sévérité ou le fix |
| 🔬 | Repose sur une hypothèse (noyau, mesure empirique, ou fichier non relu) — à vérifier, voir §8 |
| ❌ | Réfuté (aucun dans les critiques/élevés) |

---

## 1. Principes directeurs du plan

Ces principes tranchent les arbitrages tout au long du document. Ils découlent de la consigne : **intégrité > performance > robustesse > simplicité > maintenabilité**, avec préférence long terme.

1. **L'intégrité des données prime sur tout.** Un chiffre faux (montage traversé, tearing, total corrompu après suppression) est pire qu'un chiffre lent. Les fixes d'exactitude passent avant les fixes de confort.

2. **La sûreté mémoire n'est pas négociable.** Un UAF latent (B1) sous `-Ounchecked` est un crash de production non diagnosticable. On le corrige *et* on retire le fusil déchargé (`unowned(unsafe)`) sur les chemins non-chauds.

3. **Toute défaillance externe doit être observable.** Un `Process` qui échoue, une suppression qui rate, un cluster injoignable : jamais silencieux. C'est un invariant produit, pas une option.

4. **Préférer un refactor structurant à cinq rustines.** Quand plusieurs findings partagent une cause racine (état de navigation éclaté → B1/F2/F3/zoom ; mutation en place → B1/A6/A7/J4.4 ; pas de canal d'erreur → C2/C3/J2.2/J4.6), on paie une fois le socle plutôt que de multiplier les correctifs fragiles. C'est le cœur du « long terme d'abord ».

5. **Ne pas retirer les filets là où ils protègent le plus.** `-Ounchecked` sur de l'arithmétique de pointeurs bruts est le pire endroit ; on mesure avant de garder (§4, B5/S1).

6. **Le compilateur comme harnais.** La trajectoire Swift 6 strict-concurrency doit devenir le garde-fou automatique des évolutions concurrentes futures — un investissement de maintenabilité.

---

## 2. Décisions d'architecture transverses (le socle)

Avant les findings individuels, sept décisions structurantes conditionnent la moitié du plan. Chacune est présentée avec ses **axes** et le **choix recommandé**. Les findings du §4–6 y renvoient.

### D-A · Centraliser l'état de navigation dans un type `NavigationState`

**Findings couverts** : B1 (partiel), F2, F3, J3.5 (zoom out), et débloque D-E.
**Problème racine confirmé** : `selection`, `selectedRowID`, `zoomRoot`, `expanded`, `revealTarget` sont cinq variables mutées à la main dans des combinaisons différentes selon le point d'entrée (`selectDirectory`, `reveal`, `zoom`, `navigate`, `zoomOut`, `remove`). Preuve d'incohérence : `zoom(into:)` ([ScanController.swift:557](Sources/MacDirStats/ViewModel/ScanController.swift#L557)) écrit `selection` mais **pas** `selectedRowID` → désynchronisation liste/treemap (F2).

**Axes** :
- **A1. Rustines ponctuelles** : ajouter `selectedRowID` dans `zoom/zoomOut/resetZoom`, `hovered=nil` dans `recompute`. *Coût* : minutes. *Défaut* : ne supprime pas la classe de bugs ; la 6ᵉ mutation réintroduira l'incohérence.
- **A2. Type `NavigationState` avec transitions nommées** : `struct NavigationState { var zoomRoot; var selection; var selectedRowID; var expanded; var revealTarget }` + méthodes `select(_:)`, `zoom(to:)`, `reveal(_:)`, `invalidate(subtree:)`. Toutes les vues lisent, seules les transitions écrivent — invariants centralisés et **testables**.
- **A3. Dériver au lieu de stocker** : `selectedRowID` calculé depuis `selection` (le seul cas propre à `RowID` étant un fichier sélectionné). Réduit l'état, réduit les désyncs possibles.

**Recommandé** : **A2 + A3**. C'est le socle qui rend B1, F2, F3 impossibles *par construction* et prépare la migration `List(selection:)` (D-E). Effort : ~½ j. Justification long terme : chaque future feature de navigation (clavier, multi-sélection) s'y branche sans re-tisser cinq variables.

### D-B · Mutation en place → invalidation + re-scan de sous-arbre

**Findings couverts** : B1 (racine), A6 (extStats), A7 (dirCount), J4.4 (delete pendant scan), et débloque S3 (FSEvents).
**Problème racine confirmé** : `remove(directory:)` fait de la chirurgie manuelle sur une structure conçue pour l'append concurrent — soustractions d'agrégats sur toute la chaîne d'ancêtres ([ScanController.swift:508-514](Sources/MacDirStats/ViewModel/ScanController.swift#L508-L514)), détachement, purge partielle de caches — mais **oublie** `extStats` (A6), `dirCount` (A7), et laisse des `parent` pendants (B1). Pendant un scan, les workers ré-alimentent le sous-arbre détaché (J4.4).

**Axes** :
- **B1. Consolider la mutation en place** : compléter la comptabilité (soustraire `extStats`, décrémenter `dirCount`, purger la descendance de `expanded`, remonter `zoomRoot`/`selection` sur `node.parent`). *Coût* : moyen. *Défaut* : on maintient à la main un invariant à N facettes ; fragile, chaque nouvel agrégat futur devra penser à la soustraction.
- **B2. Invalidation + re-scan ciblé** : une suppression **réussie** marque `node.parent` « sale » et relance un scan local de ce seul répertoire (le scanner sait déjà tout faire : c'est une seed). Zéro comptabilité manuelle, zéro UAF possible, le sous-arbre est reconstruit propre. *Coût* : le re-scan d'un sous-arbre (ms à dizaines de ms). *Bénéfice* : supprime **définitivement** la classe B1/A6/A7 et ouvre la voie à FSEvents (même mécanique).

**Recommandé** : **B2 pour la cible, B1-minimal comme garde-fou immédiat.** En Phase 0 on pose le garde-fou de sûreté (purge `expanded`/`zoomRoot`/`selection` de la descendance + `unowned` safe, cf. §4 B1) pour tuer l'UAF *tout de suite*. En Phase 4 on remplace la chirurgie par l'invalidation-rescan, qui est la vraie réponse long terme (simplicité + intégrité). Cette double temporalité respecte « corriger le danger vite, refactorer proprement ensuite ».

### D-C · `ProcessRunner` unifié avec timeout et annulation

**Findings couverts** : C1 (racine), et prérequis de C2, C3, H1, J6.2 (start VM), J6.3, J8.1.
**Problème racine confirmé** : `VMProbe.capture` ([VMProbe.swift:37-48](Sources/MacDirStats/Scanner/VMProbe.swift#L37-L48)) fait `readDataToEndOfFile()` **bloquant, sans timeout**. Utilisé par 100 % des requêtes podman/kubectl. `stop()` ([KubernetesController.swift:69](Sources/MacDirStats/ViewModel/KubernetesController.swift#L69)) invalide le *résultat* (`loadID`) mais ne tue **jamais** le process. Un contexte kubectl mort = spinner infini + process fantôme.

**Axes** :
- **C1. Timeout local à chaque appelant** : dupliquer la logique. *Défaut* : dispersion, oublis garantis.
- **C2. Un utilitaire `ProcessRunner.run(exe, args, timeout:) async throws -> (stdout, stderr, code)`** : timeout via `Task.sleep` + `terminate()` puis `kill(SIGKILL)`, annulation coopérative (`withTaskCancellationHandler`), capture bornée de stderr (~4 Ko). Remplace *tous* les `capture`. Lit le pipe avant `waitUntilExit` (déjà l'idiome de `capture`, à conserver).

**Recommandé** : **C2.** Meilleur ratio robustesse/effort du projet (~2–3 h). Il devient le point de passage obligé qui rend C2/C3/H1 triviaux ensuite (stderr + exit code enfin disponibles). Décision de conception : le rendre `async` et *Sendable-safe* dès le départ (cohérent avec S1).

### D-D · Canal d'erreur explicite des backends

**Findings couverts** : C2 (racine), C3, J2.2 (skipped actionnable), J4.6, J6.3, H2.
**Problème racine confirmé** : `ScanBackend` n'expose que des compteurs ; stderr → `/dev/null` ([CommandScanner.swift:51](Sources/MacDirStats/Scanner/CommandScanner.swift#L51)), exit codes jamais lus, `remove()` renvoie un `Bool` **ignoré par tous les appelants** ([DirectoryListView.swift:61-67](Sources/MacDirStats/Views/DirectoryListView.swift#L61-L67)).

**Axes** :
- **D1. Bannière d'erreur ad hoc par mode** : rapide mais dupliqué 3×.
- **D2. Enrichir le contrat `ScanBackend`** : `var failure: BackendFailure? { get }`, `func diagnostics() -> String`, une phase `.failed(String)` sur les contrôleurs, un bandeau discret partagé. `remove()` : consommer le `Bool` existant → alerte sur `false`. Les N premiers chemins en échec (par errno) mémorisés côté scanner (il les jette aujourd'hui) → popover sur le chip « skipped » + CTA FDA si dominante EPERM.

**Recommandé** : **D2.** Investissement de robustesse transverse. Se fait naturellement *après* D-C (le stderr/exit code deviennent disponibles). Aligne les trois modes sur un même modèle d'erreur (maintenabilité).

### D-E · Migrer la liste vers `List(selection:)` native

**Findings couverts** : J3.1 (clavier), J4.2 (⌘⌫ + multi-sélection), J10.1 (a11y de base), et une partie de J3.7 (tri).
**Problème racine confirmé** : la `List` ([DirectoryListView.swift](Sources/MacDirStats/Views/DirectoryListView.swift)) n'utilise pas la sélection native ; tout passe par `onTapGesture`. Grep : **2** raccourcis clavier dans toute l'app (⌘O, ⌘F), zéro `onMoveCommand`/`onKeyPress`/`onDeleteCommand`/`accessibilityLabel`.

**Axes** :
- **E1. Ajouter des `onKeyPress` sur la vue custom actuelle** : possible mais on ré-implémente la sélection multiple, le focus, le range-select à la main.
- **E2. Refondre sur `List(selection:)` + `.contextMenu(forSelectionType:)`** : on gagne d'un coup ↑/↓, ⌘-clic, ⇧-clic, ⌫, menus contextuels standards et une base d'accessibilité. Nécessite de réconcilier la sélection native avec `NavigationState` (D-A) — d'où la dépendance.

**Recommandé** : **E2, après D-A.** C'est la refonte qui débloque le plus de valeur UX par unité d'effort pour l'utilisateur cible (dev senior au clavier). Dépendance explicite : faire D-A d'abord pour ne pas migrer sur un état de navigation encore éclaté.

### D-F · Trajectoire Swift 6 / retrait mesuré de `-Ounchecked`

**Findings couverts** : B5 (racine), B2, B3, et durcit tout le code concurrent.
**Problème racine confirmé** : `Package.swift` est en `swift-tools-version: 6.0` mais force `.swiftLanguageMode(.v5)` + `-Ounchecked` en release ([Package.swift:14-19](Package.swift#L14-L19)). Conséquence : le code le plus dangereux (arithmétique d'offsets `FSAttr`, pointeurs bruts) tourne **sans bounds checks** en release, et le mode v5 masque les data races formelles (B2).

**Axes / séquence recommandée** (pas un choix, une progression) :
1. Régler B2 (publier les nœuds entièrement avant visibilité — cf. §4).
2. Encapsuler l'état partagé mutable dans `Mutex<T>` (Synchronization, dispo macOS 15) : `Mutex<[WorkItem]>`, `Mutex<[ExtKey: ExtStat]>`.
3. `FSNode: @unchecked Sendable` avec un commentaire d'invariant **vrai** (tout champ mutable protégé par lock/atomic).
4. Passer `.swiftLanguageMode(.v6)`.
5. **Mesurer `-O` vs `-Ounchecked` en headless** sur un vrai scan (workload syscall-bound → pari : écart < 5 %, indistinguable). Si confirmé, retirer `-Ounchecked`.

**Recommandé** : cette séquence, en Phase 3–4. Bénéfice long terme majeur : le compilateur devient le harnais de non-régression concurrence. **🔬 À vérifier** : le gain réel d'`-Ounchecked` (étape 5) — hypothèse « négligeable », non mesurée.

### D-G · Formaliser « Comptage exact » vs « Attribution »

**Findings couverts** : A1, A3 (hardlinks), A4 (clones APFS), et la classe entière J9 (« pourquoi ça ne matche pas Finder »).
**Problème** : l'app mesure aujourd'hui la *responsabilité* (hardlinks comptés par lien — validé empiriquement par l'audit = `du -skl` ; clones pleins ; montages traversés). Ce n'est ni faux ni juste : c'est un *choix* non explicité.

**Axes** :
- **G1. Tout corriger vers l'exactitude disque** : dédup hardlinks, private-size clones, borné au volume. *Défaut* : casse la sémantique « responsabilité » utile pour « qui occupe l'espace », et change les totaux affichés sans le dire.
- **G2. Deux modes explicites** : **Exact disque** (dédup A3 + private-size A4 + borné volume A1 → matche `df`) et **Attribution** (comportement actuel, documenté). Un toggle produit.

**Recommandé** : **A1 est corrigé inconditionnellement** (un montage traversé est un *bug*, pas un mode — cf. §4). A3/A4 deviennent le mode « Exact » optionnel (Phase 4+). C'est une décision *produit* autant que technique ; elle résout d'un coup la première objection de tout utilisateur (J9). La **réconciliation** (J9) — un panneau « Total volume = scan + corbeille + snapshots + purgeable + illisible » — est le corollaire à fort impact confiance.

---

## 3. Plan par phases

Chaque phase est cohérente (livrable testable) et ordonnée par les principes du §1. Les phases 0–1 sont non négociables avant toute diffusion.

### Phase 0 — Intégrité & sûreté (bloquant, ~1 j)
Corriger les défauts qui produisent des **données fausses** ou des **crashs**.
- **A2** — ordre de parsing `ATTR_CMN_ERROR` (30 min).
- **B1** — garde-fous `remove()` (purger descendance de `expanded`, remonter `zoomRoot`/`selection`) + `parent` en `unowned` safe (1 h). *(Garde-fou de D-B ; le refactor invalidation-rescan viendra en Phase 4.)*
- **A1** — `ATTR_DIR_MOUNTSTATUS` + skip des mount points non-seed (1–2 h).
- **B2** — publication complète des nœuds sous verrou (1 h).
- **J4.4** — désactiver Trash/Delete tant que `phase == .scanning` (garde d'une ligne) (15 min).

### Phase 1 — Robustesse (~1,5 j)
Rendre toute défaillance observable et non bloquante.
- **D-C** — `ProcessRunner` (timeout + annulation), adopté partout (2–3 h).
- **D-D** — canal d'erreur : phase `.failed`, bandeau, `remove()` consommé, « skipped » actionnable, état vide K8s (C3) (½ j).
- **J4.1** — suppressions asynchrones (`Task.detached`) avec état « en cours » (1 h).

### Phase 2 — Débloquer les culs-de-sac UX (~2 j)
- **D-A** — `NavigationState` (½ j) → règle **F2**, **F3**.
- **J3.5** — dézoom (⌘↑, Échap, double-clic fond, bouton) + **corriger le README** (½ j).
- **D-E** — `List(selection:)` native → clavier, ⌘⌫, multi-sélection, a11y de base (1 j).
- **J3.2** — QuickLook (barre espace) (½ j).
- **J3.3** — chemin dans le hover du treemap (XS).

### Phase 3 — Performance & réactivité (~1,5 j)
- **E1** — cacher `filesIn` pendant le scan (1 h).
- **E6** — recherche en tâche détachée sur snapshot (½ j).
- **E3** — `CommandScanner` : propagation par lot de parent (½ j).
- **E4** — usage K8s parallèle borné (½ j, dépend de D-C pour le timeout par nœud).
- **E2/E5** — caches de tri pendant scan ; mémoïser `K8sTreemap.computeTiles` (½ j).
- **D-F** (début) — B2 réglé, `Mutex`, mesure `-Ounchecked`.

### Phase 4 — Exactitude en profondeur & modes (~2–3 j)
- **D-B (cible)** — invalidation + re-scan de sous-arbre → supprime B1/A6/A7 par construction.
- **A11** — framing NUL du `CommandScanner`.
- **A9** — tuile « non exploré » (front de scan visible).
- **H1** — détection Docker (ou message honnête).
- **J6.1** — carte « Container storage » par VM.
- **J8.1** — ping/timeout des contextes K8s morts.
- **D-G / A3 / A4** — mode « Exact » (dédup hardlinks, private-size) + panneau de réconciliation J9.

### Phase 5 — Fond de roadmap (au-delà)
- **S3** — FSEvents (dashboard vivant, même mécanique que D-B).
- **S5** — détail fichiers dans le treemap (stockage colonnaire par répertoire).
- **S6** — backends pluggables (SSH générique, Time Machine).
- **Distribution** — icône, notarisation Developer ID, About/version, cask Homebrew.
- **A11y complète**, i18n.

---

## 4. Détail des chantiers critiques et élevés

Chaque entrée : **Vérif.** · localisation · cause · **axes + tradeoffs** · **recommandation** · effort · hypothèses.

### A2 · 🔴→ 🟠 (latent) · Ordre de parsing `ATTR_CMN_ERROR` · ✅⚠️🔬

**Où** : [FSAttr.swift:71-91](Sources/MacDirStats/Scanner/FSAttr.swift#L71-L91).
**Cause** : parse NAME → OBJTYPE → ERROR ; le contrat noyau impose ERROR juste après `RETURNED_ATTRS`, donc **avant** NAME (preuve au §0).
**Nuance de sévérité (⚠️)** : la casse est **bornée à l'entrée en erreur** (chaque entrée redémarre à `entry + entryLength`). Sur un scan APFS local sain, les entrées en erreur sont rares → l'app fonctionne (c'est pourquoi le bug est *latent*). Le déclencheur : un répertoire SMB/exFAT/FUSE où des entrées retournent EACCES/EIO par entrée.

**Axes** :
- **Fix trivial (recommandé)** : déplacer le bloc erreur juste après `off += 20`, avant NAME ; si `entryError != 0`, `continue` (sauter le reste, l'avance par `entryLength` est déjà en place). C'est *exactement* l'ordre de l'exemple du man page. Aucun tradeoff : plus correct, aussi rapide.
- **Alternative défensive** : borner `nameByteOffset`/`nameLen` au buffer avant `String(decoding:)` — utile *en plus*, comme défense en profondeur contre tout futur misparse (surtout tant que `-Ounchecked`).

**Recommandé** : le fix trivial **+** le bornage défensif de la lecture de nom (ceinture et bretelles, cohérent avec le principe #2). Effort : 30 min + 15 min.
**🔬 À vérifier (§8-1)** : est-ce qu'une entrée en erreur porte *aussi* le bit `ATTR_CMN_NAME` ? Si **oui**, le code actuel lit un `attr_ref` de nom à l'emplacement de l'`errno` → nom poubelle → OOB possible sous `-Ounchecked`. Si **non** (seuls error+returned_attrs présents), le code actuel « marche par accident » (les gardes sautent name/objtype, l'erreur est lue au bon offset 24). L'exemple du man page lit le nom *avant* de tester l'erreur, ce qui **suggère** que le nom peut être présent — mais à confirmer par un test réel (fixture exFAT/SMB avec entrées EACCES). Le fix est correct dans les deux cas, donc **on l'applique sans attendre la vérification**.

### B1 · 🔴 · Use-after-free après suppression d'un ancêtre du zoom/sélection · ✅

**Où** : [FSNode.swift:18](Sources/MacDirStats/Model/FSNode.swift#L18) (`unowned(unsafe) let parent`) × [ScanController.swift:496-522](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L522).
**Cause (tracée)** : la vivacité repose sur la rétention descendante `_children`. `remove(directory: A)` fait `expanded.remove(A)` (le nœud lui-même uniquement, [ligne 516](Sources/MacDirStats/ViewModel/ScanController.swift#L516)) et `if selection === A` (égalité stricte, [ligne 517](Sources/MacDirStats/ViewModel/ScanController.swift#L517)) — mais **ne touche pas** `zoomRoot`, ni `selection`/`expanded` quand ils désignent un *descendant* de `A`. Scénario : zoom sur `A/B/C` (`reveal` a mis `A,B` dans `expanded` et `zoomRoot=selection=C`) ; supprimer `A` depuis la liste → `A,B` libérés, `C` survit via `zoomRoot`, `C.parent (=B)` **pendant**. Au rendu suivant, `zoomPath` ([ScanController.swift:565](Sources/MacDirStats/ViewModel/ScanController.swift#L565)), `selectionRect` ([TreemapView.swift:143](Sources/MacDirStats/Views/TreemapView.swift#L143)) ou `isUnderMatch` ([TreemapView.swift:176](Sources/MacDirStats/Views/TreemapView.swift#L176)) remontent `parent` → déréférencement pendu. `unowned(unsafe)` = zéro trap, `-Ounchecked` = zéro filet.

**Axes (cumulables)** :
- **Correctif fonctionnel (Phase 0)** : dans `remove(directory: N)`, *avant* le détachement (marche `parent` encore sûre) : si `zoomRoot`/`selection` descend de `N`, les remonter sur `N.parent` ; purger de `expanded` tout le sous-arbre de `N` (DFS depuis `N`). Coût : 1 h.
- **Défense en profondeur (Phase 0)** : `parent` en `unowned` (safe). Coût : un test de vivacité par déréférencement — invisible face aux syscalls (les remontées sont par *répertoire*, pas par fichier), et transforme toute récidive d'UAF en **trap diagnosticable** plutôt qu'en corruption silencieuse. Le gain d'`unowned(unsafe)` ici est une micro-opt sur un chemin non-chaud → à abandonner (principe #2).
- **Cible long terme (Phase 4)** : D-B (invalidation-rescan) rend le problème structurellement impossible.

**Recommandé** : les **trois**, dans l'ordre temporel. Le correctif fonctionnel + `unowned` safe tuent le danger immédiatement ; D-B l'élimine à la racine.
Effort : 1 h (Phase 0) ; D-B en Phase 4.

### A1 · 🟠 · Franchissement des points de montage — sur-comptage · ✅🔬

**Où** : [DirectoryScanner.recommendedSkipPaths](Sources/MacDirStats/Scanner/DirectoryScanner.swift#L73-L81) + [MountInfo.networkMountPoints](Sources/MacDirStats/Scanner/MountInfo.swift#L8-L26).
**Cause (confirmée)** : `skipPaths` ne contient que les montages **réseau** (`!MNT_LOCAL`) + `/System/Volumes/Data`. Tout montage *local* (VM swap, Preboot/Update/xarts, disques externes via firmlink `/Volumes`, DMG/translocations sous `/private/var/folders`) est descendu → compté dans « Macintosh HD ». En multi-volumes, l'externe est compté **deux fois** (sa seed + via `/Volumes` de la racine).

**Axes** :
- **1. `ATTR_DIR_MOUNTSTATUS` dans le bulk (recommandé)** : demander l'attribut répertoire `ATTR_DIR_MOUNTSTATUS` et ne pas descendre quand `DIR_MNTSTATUS_MNTPOINT` est posé, *sauf* si l'enfant est une seed. Sémantique `-xdev` **exacte**, capte les montages apparus *pendant* le scan. Coût : +4 octets/entrée répertoire, **zéro syscall** supplémentaire — mais **modifie la disposition du buffer** : il faut ajouter `dirattr` au bitmap et parser le champ (attention à l'ordre des `dirattr`, après les `fileattr` dans le buffer). Conserver le skip explicite de `/System/Volumes/Data` (firmlink, pas un mount point → non capté par MOUNTSTATUS, et nécessaire contre le double comptage).
- **2. `getmntinfo` au démarrage, diff des mount points − seeds** : sans toucher le parsing. Simple, mais **rate les montages apparus en cours de scan** et repose sur la comparaison de chemins (sensible aux préfixes, aux liens).
- **3. Toggle « Rester sur le volume »** (défaut on) : pour l'utilisateur qui *veut* le total traversant.

**Recommandé** : **Axe 1** (exactitude à la source, coût nul en syscalls), avec le toggle Axe 3 comme option produit. L'Axe 2 est un repli acceptable si l'ajout de `dirattr` au parseur s'avère risqué à court terme. Effort : 1–2 h (Axe 1) + test fixture DMG.
**🔬 À vérifier (§8-2)** : la disposition exacte des `dirattr` dans le buffer bulk (ordre relatif aux `fileattr`) et le comportement de `ATTR_DIR_MOUNTSTATUS` sur un firmlink — à valider par un petit test avant de committer le parseur. Les chiffres du sur-comptage sont ceux de l'audit (à rejouer via le test automatisé §7).

### B2 · 🟠 · Publication de nœud incomplète (tearing possible) · ✅

**Où** : [FSNode.finishScan:84-99](Sources/MacDirStats/Model/FSNode.swift#L84-L99) écrit `directFiles*` et `dominantExt` **hors verrou** puis prend `gTreeLock` pour `_children` ; [adjustDirectFiles:77-81](Sources/MacDirStats/Model/FSNode.swift#L77-L81) et [updateDominantExt:69](Sources/MacDirStats/Model/FSNode.swift#L69) écrivent sans verrou (thread lecteur du `CommandScanner`).
**Cause** : le nœud est publié (via `appendChild`/`_children` du parent sous lock) *avant* que ses champs directs soient écrits. Le main thread (`visibleRows`, `TreemapLayout`, `directFilesSize`) lit concurremment. Sur arm64 les Int64 alignés ne tearent pas en pratique ; `dominantExt` (2×UInt64) **peut** tearer → au pire couleur fausse. UB formelle, précisément ce que `-Ounchecked` + mode v5 rendent indétectable.

**Axes** :
- **Minimal** : écrire les quatre champs *sous* `gTreeLock` dans `finishScan` (une écriture par nœud côté `DirectoryScanner` → coût nul) ; pour `CommandScanner`, prendre le lock dans `adjustDirectFiles`/`updateDominantExt`.
- **Structurant (S1)** : basculer `dominantExt` en index 8 bits dans une table d'ExtKey → une pierre deux coups (supprime le tearing 2×UInt64 *et* réduit l'empreinte).

**Recommandé** : le **minimal en Phase 0** (prérequis de la migration Swift 6 propre), le structurant en Phase 3 avec D-F. Effort : 1 h.

### C1 · 🟠 · Aucun timeout/annulation sur les `Process` · ✅

Couvert par **D-C**. Détail vérifié : `KubernetesController.stop()` ([ligne 69](Sources/MacDirStats/ViewModel/KubernetesController.swift#L69)) fait `loadID += 1` — invalide le *résultat* via `guard id == loadID` mais **le process bloqué survit**. `streamLoad` boucle les nœuds en série ([lignes 92-100](Sources/MacDirStats/ViewModel/KubernetesController.swift#L92-L100)) : un seul kubelet injoignable via `nodeUsage` (blocage `capture`) fige toute la progression. Recommandation : D-C (timeout par appel) **+** E4 (parallélisme borné) sont complémentaires — sans timeout, la parallélisation ne fait que multiplier les slots bloqués.

### C2 · 🟠 · Échecs silencieux systémiques · ✅

Couvert par **D-D**. Inventaire re-vérifié :
- [CommandScanner.swift:51](Sources/MacDirStats/Scanner/CommandScanner.swift#L51) : `stderr → nullDevice`, exit code jamais lu ([ligne 118](Sources/MacDirStats/Scanner/CommandScanner.swift#L118) : `waitUntilExit()` sans lecture du code). VM sans GNU findutils/`stdbuf` (busybox/Alpine) ou `sudo` refusé → **scan « réussi » à 0 octet**.
- `remove()` renvoie `Bool` ([ScanController.swift:497,524](Sources/MacDirStats/ViewModel/ScanController.swift#L497)) → **ignoré** par `performDelete`/`moveToTrash` ([DirectoryListView.swift:61-67,219-224](Sources/MacDirStats/Views/DirectoryListView.swift#L61-L67)).
- `ContainerController.run` ([lignes 85-91](Sources/MacDirStats/ViewModel/ContainerController.swift#L85-L91)) : sortie/code de `rmi`/`prune` ignorés.
- `jsonArray`/`jsonItems` : tout échec parsing → `nil` → liste vide indistinguable de « rien à afficher ».

### C3 · 🟡 · K8s : spinner infini sur cluster vide/RBAC refusé · ✅

**Où** : [KubernetesResultView.swift:17](Sources/MacDirStats/Views/KubernetesResultView.swift#L17) : `if controller.pvcs.isEmpty { Text("Querying …") }` — condition sur `pvcs.isEmpty`, **pas** sur `state`. Un cluster sans PVC, un RBAC refusant `get pvc`, ou un kubectl absent → « Querying… » **même à `state == .ready`**.
**Fix** : brancher sur `state` (`.loading` → spinner ; `.ready && pvcs.isEmpty` → « Aucun PVC dans ce contexte » ; `.failed` → message erreur, dépend de D-D). Effort : inclus dans D-D.

### D1 · 🟠 · Suppression par chemin reconstruit — TOCTOU · ✅

**Où** : `path(for:)` ([ScanController.swift:374](Sources/MacDirStats/ViewModel/ScanController.swift#L374)) rebâtit le chemin depuis un arbre potentiellement vieux de plusieurs heures (aucune invalidation FSEvents) ; l'alerte de confirmation ([DirectoryListView.swift:48-53](Sources/MacDirStats/Views/DirectoryListView.swift#L48-L53)) n'affiche **que le nom**.
**Axes** :
- Re-`stat` la cible juste avant suppression, comparer taille agrégée/`fileID` plausibles → au moindre doute, alerte « le disque a changé, relancez le scan ».
- Enrichir l'alerte avec ce que le nœud croit supprimer (« 12 400 fichiers · 48,2 GB · modifié il y a 3 h » — données déjà dans le nœud).
- FSEvents (S3) pour marquer les sous-arbres sales.

**Recommandé** : le re-`stat` défensif + l'alerte enrichie en Phase 1–2 (proportionné, faible coût, gros gain de confiance) ; FSEvents en Phase 5. Le choix corbeille-par-défaut + confirmation dédiée pour « Delete Permanently » est **bon** et à conserver.

### E1 · 🟠 · `filesIn()` ré-énumère le disque à 10 Hz pendant le scan · ✅

**Où** : [ScanController.filesIn:344-371](Sources/MacDirStats/ViewModel/ScanController.swift#L344-L371) — cache peuplé seulement `if phase != .scanning` ([ligne 348, 369](Sources/MacDirStats/ViewModel/ScanController.swift#L348)). Pendant un scan, chaque tick 100 ms reconstruit `visibleRows` → ré-ouvre et ré-énumère **sur disque** (`open` + `enumerateDirectory`) chaque dossier étendu, **sur le main thread**.
**Axes** : cacher aussi pendant le scan avec invalidation par `(directFileCount, generation)` par entrée ; ou énumérer en tâche détachée avec placeholder.
**Recommandé** : cache versionné pendant le scan (invalidation quand `finishScan` touche le nœud). Effort : 1 h. Absorbé sur SSD local ; critique sur dossier réseau (seed ⌘O) ou 100 k fichiers directs.

### J4.1 · 🔴 (quotidien) · Suppressions synchrones sur le main thread · ✅

**Où** : `remove(directory:/file:)` est sur `@MainActor` et appelle `FileManager.removeItem`/`trashItem` en **synchrone** ([ScanController.swift:501-502,529-530](Sources/MacDirStats/ViewModel/ScanController.swift#L501)). Un `node_modules` d'1 M de fichiers en suppression définitive = dizaines de secondes de beachball. Corbeille inter-volume (externe → copie) : pire.
**Axes** : `Task.detached` pour l'opération disque, item marqué « suppression… » (opacité), ajustement des agrégats appliqué au retour sur MainActor.
**Recommandé** : suppression asynchrone (Phase 1). L'infra d'ajustement existe déjà, elle est juste appelée du mauvais thread. Interaction avec D-B : si on adopte l'invalidation-rescan, l'ajustement post-suppression devient un re-scan détaché — même flux asynchrone. Effort : 1 h.

### J3.5 · 🔴 (quotidien) · Impossible de dézoomer (+ README menteur) · ✅

**Prouvé** : `zoomOut()`/`resetZoom()` ([ScanController.swift:581-593](Sources/MacDirStats/ViewModel/ScanController.swift#L581-L593)) — **aucun appelant** (grep). Le [README:51](README.md#L51) documente « the **↖︎** button zooms out » — **bouton inexistant**. Seule issue actuelle : cliquer un segment de breadcrumb.
**Fix** : câbler `zoomOut`/`resetZoom` sur ⌘↑ / Échap / double-clic sur le fond du treemap / un bouton explicite dans le breadcrumb, **et** synchroniser `selectedRowID` (via D-A). Corriger le README. Effort : ½ j (Phase 2). Note : `zoomOut/resetZoom` mettent `selection` mais pas `selectedRowID` (même défaut que F2) → à router par `NavigationState`.

### J4.4 · 🟠 · Suppression pendant un scan actif — totaux corrompus · ✅

**Où** : le menu contextuel ([DirectoryListView.swift:181-197](Sources/MacDirStats/Views/DirectoryListView.swift#L181-L197)) n'est conditionné que par `controller.isHostScan`, **pas** par `phase`. Pendant le scan, `remove(directory:)` soustrait l'agrégat courant puis détache — mais des `WorkItem` restent en file dans ce sous-arbre : leurs contributions futures remontent la chaîne `parent` (toujours vivante) et regonflent des ancêtres « soldés ». Totaux définitivement faux + rafale d'ENOENT.
**Fix minimal (Phase 0)** : désactiver Trash/Delete tant que `phase == .scanning` (garde + item grisé). **Cible (Phase 4)** : D-B (invalidation-rescan) rend l'opération sûre même en cours de scan. Effort : 15 min (garde).

### H1 · 🟡 · Docker jamais détecté malgré l'enum · ✅

**Où** : [ContainerProbe.detect:62-69](Sources/MacDirStats/Scanner/ContainerEngine.swift#L62-L69) ne sonde que podman ; `ContainerEngine.Kind.docker` existe mais n'est **jamais instancié** (grep). Les utilisateurs Docker Desktop/colima-docker n'ont aucun mode ni message.
**Axes** : détection `docker info --format json` (via D-C pour le timeout). **Attention (H2 lié)** : les formats JSON docker ≠ podman — tailles en *strings* « 1.2GB » côté docker CLI, que le parseur actuel ([int64 helper:180-186](Sources/MacDirStats/Scanner/ContainerEngine.swift#L180-L186)) enverrait à **0** silencieusement (`Int64("1.2GB")` = nil).
**Recommandé** : détection Docker + un parseur de tailles tolérant aux suffixes humains, **ou** à défaut un message honnête « Docker détecté mais non supporté ». Effort : ½–1 j (Phase 4). Décision produit : viser le support réel plutôt que le message (Docker Desktop est le cas majoritaire).

### I1 · 🟠 · Zéro test automatisé · ✅

`Package.swift` n'a **aucun** target de test. Cibles à très haut rendement identifiées → voir §7 (stratégie dédiée).

---

## 5. Détail des chantiers moyens

### A3 · Hardlinks comptés par lien · ✅ (mode « Exact », D-G)
Validé par l'audit : total = `du -skl`. Demander `ATTR_CMN_FILEID`+`ATTR_CMN_DEVID`+`ATTR_FILE_LINKCOUNT` ; pour `nlink > 1` seulement, dédup via `Set<(dev, ino)>` (mémoire bornée aux multi-liens). Tradeoff : +attributs dans le bulk (buffer un peu plus gros). Mode optionnel, Phase 4+.

### A4 · Clones APFS non déduits · ✅🔬 (mode « Exact », D-G)
La somme des `fileAllocSize` de deux clones dépasse l'espace réel. Piste : `ATTR_CMNEXT_PRIVATESIZE` (taille non partagée). **🔬** : coût réel de l'attribut étendu (buffer plus gros) à mesurer ; disponibilité/fiabilité de `PRIVATESIZE` selon versions à vérifier. C'est la plus grosse limite de fidélité « physique » après A1.

### A5 · `getattrlistbulk == -1` silencieux · ✅
[FSAttr.swift:57](Sources/MacDirStats/Scanner/FSAttr.swift#L57) : `if count <= 0 { break }` — `-1` (EACCES en cours, EIO, volume débranché) indistinguable de la fin. Fix : distinguer `0` de `-1`, incrémenter `errorCount` (le `process()` n'ajoute que les erreurs *par entrée*, pas l'erreur syscall), idéalement marquer le nœud « partiel ». Combiner avec D-D.

### A6 · extStats non ajusté après suppression · ✅
`remove()` corrige les agrégats mais pas `extStats` (propriété du scanner) → le panneau « File types » affiche encore les octets supprimés. Résolu par D-B (le re-scan reconstruit `extStats`) ; à défaut, exposer `subtract(ext:stat:)` sur le backend ou marquer le panneau « stale ».

### A7 · dirCount figé après suppression · ✅
`dirCount` appartient au scanner ; supprimer un sous-arbre laisse le chiffre de la barre figé. Même résolution que A6 (D-B).

### A8 · Couleur de tuile = extension des fichiers *directs* seulement · ✅
[FSNode.dominantExt:33](Sources/MacDirStats/Model/FSNode.swift#L33) + [TreemapView:121,131](Sources/MacDirStats/Views/TreemapView.swift#L121) : un dossier avec 1 Ko de `.txt` direct et 500 Go de `.mp4` en sous-dossiers s'affiche « couleur .txt ». Le filtre par type souffre du même biais. Piste : propager un dominant *pondéré du sous-arbre* (fusion bottom-up à la complétion de chaque nœud). Coût : un champ + une passe. Phase 4.

### A9 · Renormalisation trompeuse du treemap pendant le scan · ✅ (par conception)
`squarify` répartit tout le rectangle entre les enfants déjà agrégés → magnitudes trompeuses tant que le scan progresse. Alternative fidèle : item fantôme « non exploré » = `parent.agg − Σ enfants publiés`, en gris neutre → l'utilisateur *voit* le front de scan. ~20 lignes, joli gain UX. Phase 4.

### A11 · `CommandScanner` : framing `\n` cassé par les noms multi-lignes · ✅
[VMProbe.swift:101](Sources/MacDirStats/Scanner/VMProbe.swift#L101) (`-printf '…%p\n'`) + [CommandScanner.swift:108](Sources/MacDirStats/Scanner/CommandScanner.swift#L108) (`firstIndex(of: 0x0A)`). Le scanner **local** gère ces noms (validé fixture) ; le VM non. Fix : `-printf '…%p\0'` + framing sur NUL (les chemins ne contiennent jamais NUL). Le chemin étant le dernier champ, les tabs sont sans risque. Phase 4.

### A12 · K8s : suffixe milli « m » → 0 · ✅
[parseQuantity:177-189](Sources/MacDirStats/Scanner/KubernetesEngine.swift#L177) : l'ordre de test des suffixes est **correct** (« Ki » avant « K », etc. — vérifié). Seule lacune : « 100m » (milli, légal mais absurde pour du stockage) tombe dans `Int64(Double("100m") ?? 0)` = 0. Impact quasi nul ; note de robustesse.

### B3 · Threads sans QoS explicite · ✅
[DirectoryScanner.swift:94-100](Sources/MacDirStats/Scanner/DirectoryScanner.swift#L94) : `Thread` sans `qualityOfService`. 12 threads saturant les syscalls peuvent concurrencer le rendu. `.utility` (ou `.userInitiated` si la vitesse prime) rend l'arbitrage explicite. Idem `CommandScanner`. Combiner avec D-F.

### B4 · `CommandScanner.cancel()` : semi-annulation · ✅
[CommandScanner.swift:71-74](Sources/MacDirStats/Scanner/CommandScanner.swift#L71) : `terminate()` + `markFinished()` immédiats, mais `readLoop` continue jusqu'à EOF et **écrit dans l'arbre après « Stop »** ([lignes 146-181](Sources/MacDirStats/Scanner/CommandScanner.swift#L146)). Le `find` distant sous `sudo` peut survivre. Fix : fermer `fileHandleForReading` pour débloquer la boucle ; kill explicite du process distant. À intégrer à D-C.

### C4 · Splash non rafraîchi (mount/unmount) · ✅
[ContentView EmptyState:411-417](Sources/MacDirStats/Views/ContentView.swift#L411) : volumes lus à l'apparition, détection VM/engine/contexts une fois. Grep : aucun observateur `NSWorkspace.didMount/didUnmount`. Brancher un USB ne fait rien. Fix : observer + bouton refresh discret.

### C5 · `KUBECONFIG` non hérité en GUI · ✅🔬
`VMProbe.locate` compense le PATH réduit des `.app` pour les *binaires*, mais `KUBECONFIG` (multi-fichiers) n'est pas géré. **🔬** : le comportement exact (kubectl lit `KUBECONFIG` de l'env ; une app Finder a-t-elle un env amputé ?) n'a pas été testé empiriquement — mécanisme plausible, à confirmer. Piste : sélecteur de kubeconfig, ou a minima documentation.

### D2 · Binaires localisés par heuristique PATH · ✅
[VMProbe.locate:25-35](Sources/MacDirStats/Scanner/VMProbe.swift#L25) scanne des dirs connus puis le PATH. Surface réelle faible (qui écrit dans `/opt/homebrew/bin` a déjà gagné). Convention pour une distribution signée : chemins absolus vérifiés. Faible.

### D3 · Prune volumes sans liste des victimes · ✅
[ContainerController.pruneVolumes:82](Sources/MacDirStats/ViewModel/ContainerController.swift#L82) : `volume prune -f` supprime **tous** les volumes non montés (bases de dev incluses). Lister les concernés (`volumes.filter { !$0.inUse }`, déjà en mémoire) = consentement éclairé, ~5 lignes.

### E2 · Tri des enfants non caché pendant le scan · ✅
[sortedChildren:329-340](Sources/MacDirStats/ViewModel/ScanController.swift#L329) : pendant le scan, tri à chaque tick (O(n log n) × 10 Hz). Pour un dossier de 50 k enfants étendu, ça se sent. Piste : cache versionné même en scan (recalcul si `childCount` bougé) ou tri partiel top-N. Phase 3.

### E3 · `CommandScanner` : propagation ancêtres par fichier · ✅
[CommandScanner.swift:162-168](Sources/MacDirStats/Scanner/CommandScanner.swift#L162) : chaque ligne fichier remonte toute la chaîne d'ancêtres. `find` émet les fichiers d'un même répertoire consécutivement → accumuler `(logical, physical, count)` tant que `parentPath` ne change pas, propager une fois. ~10× moins d'opérations. Le `DirectoryScanner` fait déjà exactement ça (asymétrie d'implémentation, pas un choix). Phase 3.

### E4 · Usage K8s séquentiel · ✅
[streamLoad:92-100](Sources/MacDirStats/ViewModel/KubernetesController.swift#L92) : un `kubectl get --raw` par nœud, **en série**. 50 nœuds × 0,5 s = 25 s. `withTaskGroup` borné à 6–8 + agrégation au fil de l'eau (÷~6). **Dépend de D-C** : timeout par nœud, sinon un nœud mort bloque sa slot. Phase 3.

### E5 · `K8sTreemap.computeTiles` recalculé à chaque hover · ✅
[KubernetesResultView.swift:310](Sources/MacDirStats/Views/KubernetesResultView.swift#L310) : `let tiles = computeTiles(...)` dans le `GeometryReader` → chaque mouvement de souris re-squarifie. Volumes faibles (pas de symptôme aujourd'hui), mais c'est l'anti-pattern que `TreemapView` évite soigneusement. Mémoïser sur `(pvcs, metric, size)` pour l'exemplarité. Phase 3.

### E6 · Recherche synchrone sur le main thread · ✅
[setSearch:71-92](Sources/MacDirStats/ViewModel/ScanController.swift#L71) : débounce 250 ms ✅ mais la marche (verrou par nœud + `range(of:.caseInsensitive)` par nom) est synchrone sur MainActor. À 500 k répertoires, dizaines à centaines de ms par frappe. Piste : recherche en tâche détachée sur snapshot (enfants déjà snapshotés sous lock) + comparaison bytes-wise ASCII-insensitive avant de payer `String.range`. Phase 3.

### F2 · Zoom ne synchronise pas la sélection liste · ✅
Résolu par **D-A**. `zoom/zoomOut/resetZoom` ([557-593](Sources/MacDirStats/ViewModel/ScanController.swift#L557)) ne touchent que `selection`, pas `selectedRowID`.

### F3 · Hover fantôme après relayout · ✅
[TreemapView.recompute:99-128](Sources/MacDirStats/Views/TreemapView.swift#L99) ne réinitialise pas `hovered`. Fix : `hovered = nil` dans `recompute`. Trivial, intégré à D-A/Phase 2.

### F4 · Recherche limitée aux dossiers · ✅
Par construction (fichiers pas en mémoire). Le placeholder « Search folders… » l'assume. Évolutions : chercher aussi dans les caches `filesIn` ouverts (gratuit) ; mode « recherche profonde » streamée. A minima, infobulle de portée.

### G1 · PVC RWX rattaché à un seul pod · ✅
[rows():243-248](Sources/MacDirStats/ViewModel/KubernetesController.swift#L243) : chaque PVC sous le premier pod qui le monte (dédup `shown`). Lisible mais trompeur. Piste : badge « shared ×N » + apparition sous chaque pod avec comptage unique dans les totaux.

### H2 · Champs `df` podman version-dépendants → zéros silencieux · ✅
[df():93-104](Sources/MacDirStats/Scanner/ContainerEngine.swift#L93) dépend de `RawSize`/`RawReclaimable` ; le parseur retombe sur 0 sans signal. Ajouter un garde « df incohérent » (Σ tailles = 0 alors que images.count > 0 → bannière). Lié à D-D.

### J1.3 · Onboarding FDA incomplet · ✅
[FDABanner:68-103](Sources/MacDirStats/Views/ContentView.swift#L68) : le texte dit « After enabling it in Settings, choose Relaunch » sans l'étape « ajoutez l'app avec **+** ». Le bandeau s'affiche **sur toutes les routes** (rendu au-dessus du switch de route, [ContentView:13](Sources/MacDirStats/Views/ContentView.swift#L13)) — bruit sur Containers/K8s où FDA n'a aucun rôle. `fdaBannerDismissed` est un `@AppStorage` **définitif** ([ligne 7](Sources/MacDirStats/Views/ContentView.swift#L7)). Fix : mini-étapes, bandeau limité à la route filesystem, re-proposition contextuelle quand `errorCount` explose sans FDA.

### J2.3 / J11.1 · App Nap non gérée · ✅
Grep : aucun `beginActivity`. Le scan en arrière-plan peut être nappé (timers throttlés, QoS abaissée). Fix (4 lignes) : `ProcessInfo.beginActivity(options: [.userInitiated], reason: "Disk scan")` à `startBackend`, `endActivity` à la fin/annulation. Ne pas empêcher la veille — seulement le nap.

### J2.4 · Quit sans confirmation pendant scan/suppression · ✅
[AppDelegate.applicationShouldTerminateAfterLastWindowClosed → true](Sources/MacDirStats/App/MacDirStatsApp.swift#L61), aucune interception. ⌘W à 80 % d'un scan de 4 To tue tout. Fix : `applicationShouldTerminate` conditionnel si `phase == .scanning` ou suppression en vol.

### J3.6 · Troncature silencieuse à 2 000 fichiers/dossier · ✅
[maxFilesPerFolder = 2000](Sources/MacDirStats/ViewModel/ScanController.swift#L309) : un dossier de 8 000 fichiers n'en montre que 2 000 (les plus gros) **sans mention**. Fix : ligne terminale « … et 6 000 fichiers de moins de X MB (Y GB) ». Le total du dossier reste juste.

---

## 6. Détail des chantiers faibles / info

Regroupés ; chacun vérifié (✅) sauf mention.

- **A10 / J9.5 · Base 1024 étiquetée « KB/MB » + locale mixte** ✅ — [Format.bytes:4-18](Sources/MacDirStats/Util/Formatting.swift#L4) : base 1024, labels « KB/MB », `String(format:)` **non localisé** ; [Format.count:21](Sources/MacDirStats/Util/Formatting.swift#L21) : `NumberFormatter` **localisé**. Un utilisateur fr voit « 1 234 567 » et « 1.5 GB » dans la même barre. Options : libellés honnêtes KiB/MiB, ou toggle base 10/1024 ; unifier la locale.
- **B5 · `-Ounchecked` + Swift 5** ✅ — couvert par D-F.
- **C6 · Headless exit code toujours 0** ✅ — [HeadlessScan.run:9-70](Sources/MacDirStats/App/HeadlessScan.swift#L9) : `--scan` sur chemin inexistant « réussit » (exit 0). Gênant pour CI. Fix : `exit(errorCount > 0 || pathInvalid ? 1 : 0)`.
- **D4 · Distribution** ✅ — signature ad-hoc, pas de notarisation, pas d'icône (`bundle.sh` ne pose aucun `CFBundleIconFile`), bundle id `com.macdirstats.app`, version figée « 1.0 ». Checklist Phase 5.
- **E7 · Budget main-thread par tick** — note de conception : cadencer différemment les 3 consommateurs (treemap 4 Hz suffit), déplacer `TreemapLayout.compute` hors main thread si besoin un jour.
- **F1 · Squarify correct** 🔬 — évalué **conforme** par l'audit (Bruls et al., gardes de dégénérescence). **Non re-vérifié dans cette passe** ([TreemapLayout.swift](Sources/MacDirStats/Views/TreemapLayout.swift) non relu) — à re-lire si on touche au layout ; sinon on fait confiance à l'audit + on couvre par les tests de propriétés (§7).
- **F5 · Casse extensions ASCII vs Unicode** ✅ — [extDisplay:238](Sources/MacDirStats/Views/DirectoryListView.swift#L238) utilise `.lowercased()` Unicode tandis qu'`ExtKey` case-folde l'ASCII seulement → divergence de couleur pour `.PDFé`. Cosmétique.
- **F6 · Détails divers** ✅ — seuils d'usage incohérents (VolumeCard 70/90 % [ContentView:497-503](Sources/MacDirStats/Views/ContentView.swift#L497) vs PieGauge K8s 70/85 %) → unifier dans `Theme` ; **code mort confirmé** (grep) : `Theme.stableUnit`, `CImage.dangling`, `CImage.created` — supprimer ou exploiter (badge « dangling », tri par âge) ; 16 teintes → collisions dès ~5 types (`stableUnit` pourrait moduler la luminosité) ; **multi-fenêtres** : `WindowGroup` partage un unique `AppModel` ([MacDirStatsApp:42](Sources/MacDirStats/App/MacDirStatsApp.swift#L42)) → deux fenêtres se voleraient l'état ; « New » retiré via `CommandGroup(replacing: .newItem)` ✅ mais envisager `Window` (scène unique) + `navigationTitle(rootName)` (grep : aucun `navigationTitle`).
- **G2 · K8s stats/summary exige nodes/proxy** ✅ — [nodeUsage:142](Sources/MacDirStats/Scanner/KubernetesEngine.swift#L142). Fallback silencieux bien géré. Pistes : `kubectl top`/metrics-server, CSI volume health.
- **G3 · Hors périmètre** — VolumeSnapshots, volumes éphémères, quotas StorageClass : extensions naturelles.
- **H3 · `ps --size` coûteux** — acceptable si le mode ne devient pas auto-rafraîchissant.
- **I2 · Diff non commité** ✅ — la feature **recherche** vit non commitée (`git diff --stat` : ScanController +68, ContentView +41, TreemapView +70, TypeBreakdownView +17). **À committer** pour borner les diffs futurs et fiabiliser tout travail dessus.
- **I3 · `bundle.sh` `|| true`** ✅ — masquerait un échec total de signature. À durcir.
- **I4 · Pas de logging structuré** ✅ — introduire `os.Logger` en même temps que D-D (diagnostics de terrain).
- **J1.1/J1.2/J1.4/J1.5** — distribution binaire, icône, usage descriptions TCC, About/version : Phase 5.
- **J2.1 · Cascade de prompts TCC** ✅ — sans FDA, prompts Desktop/Documents/Downloads pendant le scan. Piste : pré-vol optionnel, ou pousser FDA en amont (J1.3).
- **J2.5 · Cibles mouvantes (misclicks)** ✅ — tri + relayout à 10 Hz → clics sur l'élément qui vient de prendre la place. Combiné à J4.4. Pistes : hystérésis de tri, gel du reflow au survol, gating destructif pendant scan (Phase 0).
- **J2.6 · Volume éjecté en plein scan** ✅ — `open()` échoue, scan « se termine » partiel sans bannière. Croisé A5/D-D.
- **J3.4 · Pas de menu contextuel sur le treemap** ✅ — grep : `contextMenu` sur liste/images/PVC, **pas** le treemap. Flux « grosse tuile → clic droit → Corbeille » absent. Phase 2 (avec D-A/D-E).
- **J3.7 · Un seul ordre de tri** ✅ — toujours par taille décroissante ; pas de tri par nom/nombre/date, pas de colonne « % du parent ». Partiellement débloqué par D-E.
- **J3.8 · Recherche : Échap/compteur manquants** ✅ — pas d'Échap, pas de « N résultats », fichiers disparus sans explication ; comparaison non insensible à la normalisation Unicode (`é` NFC vs NFD). Ajouter `.diacriticInsensitive`/normaliser.
- **J3.9 · Fenêtre anonyme** ✅ — aucun `navigationTitle` (grep). Cf. F6 multi-fenêtres.
- **J3.10 · Splitters non persistés** 🔬 — `HSplitView`/`VSplitView` legacy sans autosave (non re-vérifié en détail ; cohérent avec le code lu). Persister via `@AppStorage` ou migrer `NavigationSplitView`.
- **J4.3 · Corbeille ≠ espace libéré** ✅ — après « Move to Trash », l'app décrémente ses totaux mais le disque n'a rien libéré. Fix : compteur de session « Déplacé vers la corbeille : X GB — [Vider] » (récompense + modèle mental explicite ; couvre aussi J4.5 « Put Back »).
- **J5.1 · Rescan = tout perdre** ✅ — `startBackend` réinitialise tout (`zoomRoot`/`expanded`/`selection`). Fix : mémoriser `zoomPath`/sélection en **chemins** (les nœuds meurent, les chemins survivent) et les re-résoudre à la fin du rescan (`path(for:)` existe).
- **J5.2 · Staleness sans indicateur** ✅ — pas d'« scanné il y a 3 h ». A minima l'âge du scan dans la barre + re-`stat` avant action destructive (D1).
- **J6.1 · Scope containers VM non exposé** ✅ — `VMScope.containers` seulement en headless ([HeadlessScan:85](Sources/MacDirStats/App/HeadlessScan.swift#L85)) ; le splash ne crée que `VMCard(scope: .full)` ([ContentView:370](Sources/MacDirStats/Views/ContentView.swift#L370)). Une 2ᵉ carte « Container storage » suffit. Phase 4.
- **J6.2 · VM stoppée sans action** ✅ — carte grisée honnête, mais pas de bouton « Démarrer » (`podman machine start`, via D-C).
- **J6.3 · Scan VM vide « réussi »** ✅ — cf. C2 ; pré-vol `command -v find && find --version` pour discriminer GNU/busybox.
- **J6.4 · `-xdev` bien pensé** ✅ (positif) — exclut les montages virtiofs/sshfs du home hôte ([VMProbe:101](Sources/MacDirStats/Scanner/VMProbe.swift#L101)). À documenter.
- **J7.x · Containers** ✅ — Docker (H1), incohérence d'affordance (VM stoppée grisée vs section Containers qui disparaît), `rmi -f` sous-documenté (dépendances supprimées), pas de visualisation surfacique (réutiliser `TreemapLayout.squarify`), prune sans inventaire (D3).
- **J8.x · K8s** ✅ — contextes morts → spinner (J8.1, avec D-C : ping `kubectl version --request-timeout=2s`), pas de filtre (J8.2), KUBECONFIG (C5/J8.3), jauges vides 30–60 s (E4/J8.4).
- **J10.x · Accessibilité** ✅ — grep : zéro `accessibility*`. VoiceOver inutilisable (treemap = `Canvas`, lignes = `HStack+onTapGesture`). D-E donne une base ; `accessibilityLabel` sur les lignes + `accessibilityChildren` sur le treemap atteignables. Daltonisme (info portée par la seule teinte), tailles figées 9–13 pt. Phase 5.
- **J11.x · Énergie** ✅ — App Nap (J2.3), `timer.tolerance` absent (grep — [ScanController:597](Sources/MacDirStats/ViewModel/ScanController.swift#L597), `timer.tolerance = 0.02` gratuit), pas d'égard `isLowPowerMode`, RAM du scan VM (`nodes: [String: FSNode]` garde un chemin complet par répertoire, [CommandScanner:28](Sources/MacDirStats/Scanner/CommandScanner.swift#L28)).

---

## 7. Stratégie de test

**Constat (I1, ✅)** : `Package.swift` n'a aucun target de test, alors que le projet regorge de pur-fonctions testables. C'est le chantier au meilleur rendement de fiabilité.

**Mise en place** : un target `swift-testing` + `swift test` en CI GitHub Actions macOS (~½ j de mise en place).

**Cibles prioritaires** (par valeur décroissante) :

1. **Le test d'or (exactitude)** — le plus important : fixture générée par script (fichier sparse 1 Mo logique, symlink, paire de hardlinks, nom contenant `\n`, Unicode, dotfile) → `MacDirStats --scan` comparé à `du -skl` **à l'octet près**. Puis fixture + **DMG APFS monté à l'intérieur** comparée à `du -skx` — ce test **échoue aujourd'hui** (A1) et **doit passer** après le fix. C'est le test de non-régression de l'intégrité, à écrire *avant* le fix A1 (TDD).
2. **`FSAttr` / `enumerateDirectory`** — fuzz de buffers (y compris entrées avec bit erreur + nom) → jamais de crash, jamais d'OOB. Verrouille A2 et la vérification 🔬 §8-1.
3. **`TreemapLayout.squarify`** — propriétés : Σ aires = aire cible ± ε, aucun chevauchement, ordre d'entrée préservé, robustesse aux totaux nuls/négatifs. Couvre F1 sans relire tout le code.
4. **`CommandScanner.parse`** — golden lines + noms hostiles (tabs, `\n` une fois A11 fait, chemins profonds) → verrouille A11 et E3.
5. **`ExtKey`** — fuzz bytes → jamais de crash, idempotence du case-fold ASCII.
6. **`K8sQueries.parseQuantity`** — table de cas (`8Gi`, `100Mi`, `1Ti`, `500M`, `100m`, vide, garbage) → verrouille A12.
7. **`Format.bytes` / `Format.count`** — table + décision base 1024/locale (A10).
8. **`remove()` + `NavigationState`** (après D-A/D-B) — tests de propriété : après toute suppression, aucun `parent` pendant, `zoomRoot`/`selection` valides, conservation `root.agg = Σ directFiles`. Verrouille B1/A6/A7.

**Principe** : chaque fix critique (A1, A2, B1, B2) arrive **avec** son test de non-régression. C'est la garantie que le long terme ne régresse pas.

---

## 8. Ce qui reste à vérifier empiriquement

Liste consolidée des hypothèses (🔬) — à lever avant de considérer les chantiers concernés « clos ».

1. **A2 — le noyau inclut-il `ATTR_CMN_NAME` dans une entrée en erreur ?** Détermine si le bug actuel est un crash/OOB (nom présent → misparse) ou un simple sur-comptage d'erreurs (nom absent → marche par accident). *Test* : fixture sur volume exFAT/SMB avec entrées provoquant EACCES/EIO par entrée, avant/après fix, sous `-Ounchecked`. **Le fix s'applique indépendamment** (correct dans les deux cas).
2. **A1 — disposition des `dirattr` dans le buffer bulk** et comportement de `ATTR_DIR_MOUNTSTATUS` sur un firmlink (`/System/Volumes/Data`). *Test* : petit programme qui demande `ATTR_DIR_MOUNTSTATUS` et dumpe les offsets, sur `/` et sur un DMG monté. Les **chiffres de sur-comptage** de l'audit (+850 Ko, 2,38 Mo) sont à rejouer via le test d'or (§7-1).
3. **A4 — coût et fiabilité de `ATTR_CMNEXT_PRIVATESIZE`** (buffer plus gros, disponibilité selon versions APFS).
4. **B5/D-F — gain réel d'`-Ounchecked`** sur un scan headless (`-O` vs `-Ounchecked`). Hypothèse : < 5 %, indistinguable (syscall-bound). *Test* : benchmark headless sur gros arbre.
5. **C5/J8.3 — `KUBECONFIG` réellement amputé** dans une app lancée par Finder. *Test* : lancer l'app depuis Finder avec un `KUBECONFIG` multi-fichiers exporté dans `~/.zshenv` et vérifier les contextes listés vs terminal.
6. **F1 — squarify** : évalué correct par l'audit mais [TreemapLayout.swift](Sources/MacDirStats/Views/TreemapLayout.swift) **non relu dans cette passe** → couvrir par les tests de propriétés (§7-3) plutôt que par une relecture, sauf si on modifie le layout.
7. **J3.10 — autosave des splitters** : cohérent avec le code lu mais non re-vérifié en détail.

**Fichiers non relus dans cette passe** (findings de faible sévérité, trust audit) : `TreemapLayout.swift`, `KubernetesResultView.swift` (partiellement, seuls les points C3/E5 vérifiés par grep), `TypeBreakdownView.swift`, `ContainerResultView.swift`, `Volume.swift`, `FullDiskAccess.swift`, `ExtKey.swift`, `ScanBackend.swift`. Aucun ne porte de finding critique/élevé.

---

## 9. Tableau de séquencement récapitulatif

| Phase | Chantiers | Findings couverts | Effort | Gate |
|---|---|---|---|---|
| **0 · Intégrité & sûreté** | A2 parsing · B1 garde-fous + `unowned` safe · A1 mount status · B2 publication sous lock · J4.4 gating delete | A2, B1, A1, B2, J4.4 | ~1 j | **Bloquant diffusion** |
| **1 · Robustesse** | D-C ProcessRunner · D-D canal d'erreur · J4.1 delete async · A5 · D1 re-stat | C1, C2, C3, A5, D1, J2.2, J4.6, H2 | ~1,5 j | **Bloquant diffusion** |
| **2 · UX débloquée** | D-A NavigationState · J3.5 dézoom+README · D-E List native · J3.2 QuickLook · J3.3/J3.4 hover+menu treemap | F2, F3, J3.5, J3.1, J4.2, J3.2, J3.3, J3.4, J10.1(base) | ~2 j | — |
| **3 · Performance** | E1 · E6 · E3 · E4 · E2/E5 · D-F (B2, Mutex, mesure) | E1, E2, E3, E4, E5, E6, B3, B5, J2.3, J11.2 | ~1,5 j | — |
| **4 · Exactitude & modes** | D-B invalidation-rescan · A11 NUL · A9 · H1 Docker · J6.1 · J8.1 · D-G mode Exact + J9 réconciliation | B1(racine), A6, A7, A11, A9, A3, A4, A8, H1, J6.1, J8.1, J9 | ~2–3 j | — |
| **5 · Roadmap** | S3 FSEvents · S5 détail fichiers · S6 backends · distribution · a11y complète · i18n | S3, S5, S6, D2, D3, D4, J1.x, J10.x | continu | — |
| **Transverse** | Tests (I1) livrés **avec** chaque fix ; committer I2 en préalable | I1, I2, I3, I4 | ½ j + inline | — |

---

*Plan établi par re-lecture du code source (18/28 fichiers lus intégralement, dont 100 % des chemins critiques), vérification du contrat noyau `getattrlistbulk` sur la machine, preuve par grep des affirmations de code mort/manquant, et inspection du diff non commité. Les findings A1, A2, B1, B2 et l'ensemble des critiques/élevés ont été confirmés dans le code ; les hypothèses résiduelles sont isolées au §8. Priorité assumée : intégrité et sûreté d'abord, refactors structurants (D-A à D-G) plutôt que rustines, long terme sur effort immédiat.*
