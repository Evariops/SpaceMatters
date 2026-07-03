# Audit technique complet — MacDirStats

> **Date** : 2026-07-02 · **Périmètre** : totalité du code (`Sources/`, `Package.swift`, `bundle.sh`, ~5 250 lignes), y compris le diff non commité (recherche de dossiers).
> **Méthode** : lecture exhaustive du code + vérifications empiriques (man pages XNU, table des montages, build + scan headless sur fixture contrôlée comparé à `du`).

---

## 0. Résumé exécutif

MacDirStats est une base **remarquablement saine pour son âge** (3 commits) : le cœur algorithmique est juste, le modèle mémoire "un nœud par répertoire" est le bon choix, et l'obsession réactivité (arbre live + atomics + version bump) est réellement implémentée, pas juste revendiquée. L'exactitude des tailles a été **validée empiriquement** dans cet audit : sur une fixture avec fichiers sparse, symlinks, hardlinks, noms contenant des retours à la ligne et de l'Unicode, le total physique correspond **à l'octet près** à `du -skl`.

Trois problèmes sérieux ressortent néanmoins :

| # | Sévérité | Constat |
|---|----------|---------|
| [A1](#a1) | 🟠 Élevé | **Le scanner traverse les points de montage** : un scan de « Macintosh HD » compte le swap (`/System/Volumes/VM`), Preboot, Update, les DMG montés et les disques externes via `/Volumes`. **Prouvé empiriquement** (scan d'un dossier contenant un DMG monté : +850 Ko fantômes vs `du -x`). |
| [A2](#a2) | 🔴 Critique (latent) | **`ATTR_CMN_ERROR` est parsé au mauvais offset** dans `FSAttr.swift` : le man page garantit qu'il est packé *juste après* `ATTR_CMN_RETURNED_ATTRS`, donc *avant* le nom. Toute entrée en erreur décale tous les offsets → entrée fantôme, tailles corrompues, lecture hors buffer possible (aggravé par `-Ounchecked`). |
| [B1](#b1) | 🔴 Critique | **Use-after-free via `unowned(unsafe) parent`** : supprimer un dossier qui est un *ancêtre* du zoom treemap courant (ou d'un nœud sélectionné/étendu) laisse des chaînes `parent` pendantes ; le fil d'Ariane (`zoomPath`) les déréférence au rendu suivant → UB silencieuse, crash ou corruption. |

Le reste se répartit entre gestion d'erreurs quasi absente (tous les échecs de `Process` sont silencieux, aucun timeout), courses de données formelles (bénignes sur arm64 mais sans filet avec `-Ounchecked` + mode Swift 5), dettes UX de synchronisation de sélection, et une absence totale de tests pour du code pourtant très testable.

**Verdict** : architecture et algorithmes ✅, exactitude locale ✅ (hors franchissement de montage), robustesse aux erreurs ❌, sûreté mémoire des mutations post-scan ❌, industrialisation (tests/CI) ❌.

---

## 1. Méthodologie et preuves

1. **Lecture exhaustive** des 30 fichiers Swift, scripts et manifestes.
2. **Vérification du contrat noyau** : `man getattrlist` sur la machine cible confirme : *« The ATTR_CMN_ERROR attribute will be after ATTR_CMN_RETURNED_ATTRS attribute in the returned buffer »* → contredit l'ordre de parsing implémenté (nom → objtype → erreur).
3. **Table des montages réelle** : `mount` montre `/System/Volumes/{VM, Preboot, Update, xarts, iSCPreboot, Hardware}` + un DMG applicatif monté sous `/private/var/folders/...` — tous locaux, tous traversés par le scanner actuel.
4. **Fixture contrôlée** (10 fichiers : sparse 1 Mo logique, symlink, paire de hardlinks, nom avec `\n`, Unicode, dotfile) :
   - `MacDirStats --scan` → physical = **1 679 360 octets = 1 640 Kio = `du -skl` exactement** (hardlinks comptés par lien, comme documenté dans le README). Logique, comptage de fichiers, types : corrects.
   - Même fixture avec un DMG APFS de 8 Mo monté dedans : l'app retourne **2,38 Mo** là où `du -skx` (un seul filesystem) retourne 1 608 Kio → **franchissement de montage confirmé**.

---

## 2. Architecture — évaluation d'ensemble

```
AppModel (routeur de modes)
 ├─ ScanController  ──> ScanBackend ├─ DirectoryScanner (getattrlistbulk, pool de threads)
 │   (filesystem)                   └─ CommandScanner  (find streamé via SSH/VM)
 ├─ ContainerController ──> ContainerQueries (CLI podman, JSON)
 └─ KubernetesController ──> K8sQueries (kubectl, JSON, chargement progressif)
Modèle : FSNode (1 nœud/répertoire, agrégats atomiques, fichiers on-demand)
Vues : TreemapView (Canvas equatable + cache de layout), DirectoryListView (List plate virtualisée), splash multi-cibles
```

### Points forts confirmés (à préserver)

- **`ScanBackend` comme frontière d'abstraction** ([ScanBackend.swift](Sources/MacDirStats/Scanner/ScanBackend.swift)) : deux implémentations radicalement différentes (syscalls locaux vs `find` streamé) alimentent le même arbre live. C'est le bon axe d'extension (SSH générique, archives, etc.).
- **Protocole de terminaison du pool** ([DirectoryScanner.swift:133-168](Sources/MacDirStats/Scanner/DirectoryScanner.swift#L133-L168)) : comptage `outstanding` classique et **correct** — chaque item empilé porte exactement +1, terminaison ssi `outstanding == 0`, donc pile vide garantie. Le hand-off de `NSCondition` fournit l'arête *happens-before* qui rend les écritures des workers visibles au main thread quand `isFinished` passe à vrai. Analysé en détail : pas de deadlock possible (les trois verrous `cond`/`gTreeLock`/`extLock` ne sont jamais imbriqués).
- **Snapshot COW sous verrou global** ([FSNode.swift:48-51](Sources/MacDirStats/Model/FSNode.swift#L48-L51)) : le lecteur récupère le buffer sous lock et le retient — idiome juste et peu coûteux.
- **Réactivité par version bump** : le treemap ne relayoute que sur `version`/`zoomRoot`/`metric`, le Canvas est `Equatable` sur `(generation, isDark, highlightVersion)` — le hover/sélection ne redessine jamais la carte. C'est exactement le découplage qu'il faut.
- **`ExtKey`** ([ExtKey.swift](Sources/MacDirStats/Model/ExtKey.swift)) : 16 octets inline, zéro allocation par fichier — design excellent, parsing borné et défensif.
- **`VMProbe.capture`** lit le pipe *avant* `waitUntilExit` — évite le deadlock classique pipe-plein. Le streaming du `CommandScanner` bénéficie d'une backpressure naturelle (pipe bloquant).
- **Détection FDA par `open()` sur TCC.db** ([FullDiskAccess.swift](Sources/MacDirStats/Util/FullDiskAccess.swift)) : plus fiable que `access()`, multi-sondes, relaunch géré. Le commentaire de `bundle.sh` sur la stabilité du cdhash est du vécu correctement documenté.
- **Chargement K8s progressif avec garde `loadID`** ([KubernetesController.swift:56-102](Sources/MacDirStats/ViewModel/KubernetesController.swift#L56-L102)) : idiome anti-course propre pour invalider les chargements obsolètes.
- **Couleurs déterministes FNV-1a** ([Theme.swift:66-73](Sources/MacDirStats/App/Theme.swift#L66-L73)) : stables entre lancements, contrairement à `Hasher` seedé par process — détail qui montre le soin porté.

### Faiblesses structurelles

- **`ScanController` God-object naissant** (~650 lignes) : cycle de vie du scan + construction de l'outline + listing fichiers on-demand + résolution de chemins + suppression + recherche + zoom + stats. Chaque responsabilité est individuellement bien écrite, mais l'agrégat rend les invariants croisés (sélection/zoom/expansion/caches) fragiles — cf. [B1](#b1), [F2](#f2). Extraction naturelle : `OutlineBuilder`, `PathResolver`, `FileLister`, `DeletionService`.
- **État de navigation éclaté** : `selection`, `selectedRowID`, `zoomRoot`, `expanded`, `revealTarget` sont cinq variables mutées à la main dans des combinaisons différentes selon le point d'entrée (tap treemap, double-clic liste, breadcrumb, delete). Deux incohérences déjà présentes ([F2](#f2), [B1](#b1)). Un type `NavigationState` avec des transitions nommées (`select`, `zoom`, `reveal`, `invalidate(subtree:)`) rendrait les invariants centralisés et testables.
- **Aucun canal d'erreur** : les backends n'exposent que des compteurs ; `Process` qui échoue, stderr, exit codes, suppressions ratées — tout est avalé. Cf. [C1](#c1)–[C3](#c3).

---

## 3. Findings détaillés

Échelle : 🔴 Critique (UB/crash/perte de données) · 🟠 Élevé (résultats faux, blocages) · 🟡 Moyen · 🔵 Faible · ⚪ Info/piste.

### 3.A Exactitude des données et intégrité des comptages

<a id="a1"></a>
#### A1 · 🟠 · Franchissement des points de montage — sur-comptage prouvé

**Où** : [DirectoryScanner.swift:73-81](Sources/MacDirStats/Scanner/DirectoryScanner.swift#L73-L81) (`recommendedSkipPaths` ne skippe que les montages *réseau* + `/System/Volumes/Data`).

**Constat** : le scan descend dans tout montage *local* rencontré. Conséquences concrètes sur un scan « Macintosh HD » (`/`) :
- `/System/Volumes/VM` → **les swapfiles** (plusieurs Go sous pression mémoire) attribués au disque système ;
- `/System/Volumes/Preboot`, `Update`, `xarts`, `iSCPreboot`, `Hardware` → volumes APFS distincts du même conteneur, comptés dans « Macintosh HD » ;
- `/Volumes/<DisqueExterne>` (firmlink `/Volumes` → Data) → **les disques externes sont comptés dans le disque interne** ; en scan multi-volumes, l'externe est compté **deux fois** (une fois sous sa seed, une fois via `/Volumes` de la seed racine) ;
- DMG et translocations montés sous `/private/var/folders/...` (présents sur la machine au moment de l'audit) → comptés.

**Preuve** : fixture + DMG APFS monté à l'intérieur → app : 2 498 560 octets ; `du -skx` : 1 646 592 octets. Écart = contenu + métadonnées du volume monté.

**Impact** : le total ne correspond ni au « used » affiché sur la carte du volume (issu des capacités par volume), ni à `du -x`, ni à Finder. La promesse « matches du -sk » du README n'est vraie que pour un dossier sans montage imbriqué.

**Options** :
1. **(Recommandé)** Demander `ATTR_DIR_MOUNTSTATUS` dans le `getattrlistbulk` et ne pas descendre quand `DIR_MNTSTATUS_MNTPOINT` est posé, sauf si l'enfant est une seed. Coût : +4 octets/entrée répertoire, zéro syscall supplémentaire, sémantique `-xdev` exacte. Conserver l'exception firmlink actuelle (les firmlinks ne sont pas des mount points, la traversée Data reste naturelle — et le skip explicite de `/System/Volumes/Data` reste nécessaire pour éviter le double comptage).
2. Alternative sans changer le parsing : `skip = tous les points de montage (getmntinfo) − seeds`, calculé au démarrage du scan. Simple, mais rate les montages apparus en cours de scan et repose sur la comparaison de chemins (sensible aux préfixes).
3. Exposer un toggle « Rester sur le volume » (défaut : on) pour les utilisateurs qui *veulent* le total traversant.

**Effort** : ~1–2 h (option 1) + test fixture DMG à automatiser (celui de cet audit est rejouable).

<a id="a2"></a>
#### A2 · 🔴 (latent) · Ordre de packing de `ATTR_CMN_ERROR` erroné dans le parseur bulk

**Où** : [FSAttr.swift:69-103](Sources/MacDirStats/Scanner/FSAttr.swift#L69-L103) — parse `NAME` (off 24), puis `OBJTYPE`, puis `ERROR`.

**Constat** : le man page (vérifié sur la machine) est explicite : l'attribut erreur est packé **immédiatement après `ATTR_CMN_RETURNED_ATTRS`**, donc *avant* le nom. L'exemple du man page parse d'ailleurs l'erreur en premier. Quand une entrée porte le bit erreur (`commonReturned & cmnError`), le code lit :
- l'`attr_ref` du nom **à l'emplacement de l'erreur** → `nameOffset` = errno (ex. 13), `nameLen` = premier champ du vrai attr_ref du nom → pointeur/longueur de nom incohérents ;
- tous les offsets suivants décalés de 4 → `objType` et tailles corrompus.

**Scénario de défaillance** : un répertoire sur SMB/FUSE/exFAT où certaines entrées retournent EACCES/EIO par entrée → `String(decoding:)` sur une longueur poubelle peut lire hors du buffer de 256 Ko → crash (et `-Ounchecked` supprime les vérifications d'indices qui auraient trappé plus tôt). Au mieux : entrées fantômes avec noms/tailles aléatoires dans l'arbre.

**Fix** (trivial, ~30 min) : lire l'erreur juste après `commonReturned` :

```swift
var entryError: UInt32 = 0
if commonReturned & FSAttr.cmnError != 0 {
    entryError = entry.loadUnaligned(fromByteOffset: off, as: UInt32.self)
    off += 4
}
// puis NAME, puis OBJTYPE, comme dans l'exemple du man page
```

Et en cas d'erreur, `continue` vers l'entrée suivante via `entryLength` (déjà le cas — l'avance se fait par `entryLength`, ce qui borne les dégâts à l'entrée fautive une fois l'ordre corrigé).

#### A3 · 🟡 · Hardlinks comptés par lien (assumé, mais proposable en option)

Validé empiriquement : le total = `du -skl`, pas `du -sk`. C'est le choix WinDirStat, documenté dans le README — légitime pour « qui est responsable de l'espace », faux pour « combien je récupère en supprimant ». **Option** : demander `ATTR_CMN_FILEID` + `ATTR_CMN_DEVID` + `ATTR_FILE_LINKCOUNT` dans le bulk ; pour les seules entrées `nlink > 1`, dédupliquer via un `Set<(dev, ino)>` (mémoire bornée par le nombre de fichiers multi-liens, marginal en pratique). Exposer « mode exact (dédupliqué) » vs « mode responsabilité ». Effort : ~2–3 h.

#### A4 · 🟡 · Clones APFS (copy-on-write) non déduits

Deux fichiers clonés (`cp -c`, duplication Finder) partagent leurs blocs : la somme des `fileAllocSize` dépasse l'espace réellement consommé — l'écart vs Finder/`df` peut être de dizaines de Go sur une machine de dev (caches, photothèques). Pistes : `ATTR_CMNEXT_PRIVATESIZE` (taille non partagée, par fichier) en attribut étendu optionnel ; ou au minimum une note UI « les clones APFS peuvent gonfler ce total ». Tradeoff : attributs étendus = buffer plus gros, à mesurer. C'est la limite de fidélité « physique » la plus importante après A1.

#### A5 · 🔵 · `getattrlistbulk` retournant −1 : perte silencieuse

[FSAttr.swift:57](Sources/MacDirStats/Scanner/FSAttr.swift#L57) : `if count <= 0 { break }` — un `-1` (EACCES en cours de listing, EIO, volume débranché) est indistinguable d'une fin normale : répertoire silencieusement tronqué, aucun incrément de `errorCount`. Fix : distinguer `0` de `-1`, compter l'erreur (et idéalement marquer le nœud « partiel »).

#### A6 · 🔵 · Table des extensions non ajustée après suppression

[ScanController.swift:496-546](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L546) : `remove(directory:/file:)` corrige les agrégats des ancêtres mais pas `extStats` du scanner → le panneau « File types » continue d'afficher les octets supprimés. Incohérence visible (l'utilisateur supprime 50 Go de `.mp4`, la ligne `.mp4` ne bouge pas). Fix : le backend expose `subtract(ext:stat:)`, ou marquer le panneau « stale » après suppression.

#### A7 · 🔵 · Compteur « folders » non décrémenté après suppression d'un dossier

`dirCount` appartient au scanner ; la suppression d'un sous-arbre laisse le chiffre de la barre d'état figé au total du scan.

#### A8 · 🔵 · Couleur de tuile = extension dominante des fichiers **directs** uniquement

[FSNode.swift:31-33](Sources/MacDirStats/Model/FSNode.swift#L31-L33) + [TreemapView.swift:121](Sources/MacDirStats/Views/TreemapView.swift#L121) : quand un répertoire est rendu comme tuile-feuille (cap de profondeur 14 ou tuile < 10 px), sa couleur vient de `dominantExt` = dominant de ses *propres* fichiers. Un dossier avec 1 Ko de `.txt` direct et 500 Go de `.mp4` en sous-dossiers s'affiche « couleur .txt ». Le filtre par type (spotlight) souffre du même biais : les tuiles agrégées ne s'allument que si leurs fichiers *directs* matchent. Piste : propager en fin de scan un dominant *pondéré du sous-arbre* (fusion bottom-up des tables locales, ou simple max entre dominant direct et dominants enfants pondérés par taille). Coût : un champ de plus, une passe à la complétion de chaque nœud.

#### A9 · 🔵 · Pendant le scan, le treemap renormalise sur la somme partielle

`squarify` répartit **tout** le rectangle entre les enfants déjà agrégés : tant que 10 % du sous-arbre est scanné, ces 10 % occupent 100 % de la surface — proportions relatives justes, magnitudes trompeuses (les tuiles « rétrécissent » au fil du scan). Alternative fidèle : ajouter un item fantôme « non exploré » = `parent.agg − Σ enfants publiés` (calculable sans état supplémentaire), rendu en gris neutre — l'utilisateur *voit* le front de scan. Joli gain UX pour ~20 lignes.

#### A10 · ⚪ · « KB/MB » affichés mais base 1024

[Formatting.swift](Sources/MacDirStats/Util/Formatting.swift) : assumé en commentaire, cohérent avec `du`, mais Finder est en base 10 → un même fichier affiche deux tailles différentes selon l'app. Options : libellés honnêtes (KiB/MiB), ou toggle base 10/1024 à côté du toggle On disk/Logical.

#### A11 · 🔵 · `CommandScanner` : framing par `\n` cassé par les noms de fichiers contenant un retour à la ligne

[VMProbe.swift:101](Sources/MacDirStats/Scanner/VMProbe.swift#L101) + [CommandScanner.swift:108-116](Sources/MacDirStats/Scanner/CommandScanner.swift#L108-L116) : `find -printf '...%p\n'` — un `\n` dans un nom coupe l'enregistrement en deux lignes invalides (rejetées par les gardes) → fichiers perdus, voire chemin tronqué rattaché au mauvais parent. Le scanner **local** gère ces noms (validé sur fixture) ; le scanner VM non. Fix : `-printf '...%p\0'` et framing sur NUL (les chemins ne peuvent pas contenir NUL). Les tabs, eux, sont sans risque : le chemin est le dernier champ.

#### A12 · 🔵 · K8s : `used` par PVC — écrasement dernier-nœud-gagnant

[KubernetesEngine.swift:140-157](Sources/MacDirStats/Scanner/KubernetesEngine.swift#L140-L157) : correct pour RWO ; pour un RWX monté sur N nœuds, les kubelets rapportent chacun le même filesystem → valeur identique, OK en pratique. À garder en tête si un jour les volumes bloc/locaux entrent au périmètre. `parseQuantity` : solide (ordre de test des suffixes correct, vérifié) ; seule lacune : le suffixe milli « m » (légal quoique absurde pour du stockage) → 0.

### 3.B Concurrence, mémoire, UB

<a id="b1"></a>
#### B1 · 🔴 · Use-after-free : suppression d'un ancêtre de `zoomRoot`/`selection`/nœuds étendus

**Où** : [FSNode.swift:18](Sources/MacDirStats/Model/FSNode.swift#L18) (`unowned(unsafe) let parent`) × [ScanController.swift:496-522](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L522) (`remove(directory:)`).

**Mécanique** : la vivacité de l'arbre repose sur la chaîne de rétention descendante (`_children`). `remove(directory: N)` détache `N` de son parent ; `N` est alors désalloué **sauf** s'il est retenu ailleurs — et ses descendants survivants (retenus par `expanded: Set<FSNode>`, `selection`, `zoomRoot`) gardent des pointeurs `parent` **non retenus et non annulés** vers des nœuds libérés.

**Scénario concret** : zoomer dans le treemap sur `…/A/B/C` (le tap `reveal` a mis les ancêtres dans `expanded`), puis dans la liste supprimer `A` (visible, la liste montre tout l'arbre indépendamment du zoom). `remove` ne touche ni `zoomRoot` ni `expanded` au-delà de `N` lui-même → au rendu suivant, `Breadcrumb.body` appelle `zoomPath` qui remonte `C.parent → B.parent → A` **libéré** → lecture d'un pointeur pendu, `unowned(unsafe)` = zéro trap, `-Ounchecked` = zéro filet → crash ou lecture de mémoire recyclée (la marche continue « au hasard »). Même exposition via `selectionRect(for:)`, `expandAncestors`, `path(for:)`, `isUnderMatch`.

**Fixes** (cumulables) :
1. **Correctif fonctionnel** : dans `remove(directory: N)`, avant le détachement — si `zoomRoot`/`selection` descend de `N` (marche parent, encore sûre à ce moment), les remonter sur `N.parent` ; purger de `expanded` tous les nœuds du sous-arbre de `N` (une DFS depuis `N` suffit).
2. **Défense en profondeur** : passer `parent` en `unowned` (safe). Coût : un test de vivacité par déréférencement — invisible face aux syscalls, et transforme toute récidive d'UB en trap diagnosticable. Le gain d'`unowned(unsafe)` ici est une micro-optimisation sur un chemin qui n'est *pas* chaud (les remontées se font par répertoire, pas par fichier).
3. Long terme : cf. [S2](#s2) (mutations = reconstruction de snapshot, plus de mutation en place).

**Effort** : 1 h pour (1)+(2).

#### B2 · 🟠 · Courses de données formelles sur `directFiles*` / `dominantExt`

**Où** : [FSNode.swift:84-99](Sources/MacDirStats/Model/FSNode.swift#L84-L99) (`finishScan` écrit `directFilesLogical/Physical/Count` et `dominantExt` **hors verrou**), [FSNode.swift:77-81](Sources/MacDirStats/Model/FSNode.swift#L77-L81) (`adjustDirectFiles`, appelé par le thread lecteur du `CommandScanner` pendant que le main thread lit), [FSNode.swift:69](Sources/MacDirStats/Model/FSNode.swift#L69) (`updateDominantExt`).

Le nœud est *publié* (via `finishScan`/`appendChild` du parent, sous `gTreeLock`) **avant** que ses propres champs directs ne soient écrits par un autre worker. Le main thread (`visibleRows`, `TreemapLayout`, `directFilesSize`) lit donc ces champs concurremment aux écritures. Sur arm64, les Int64 alignés ne « tearent » pas en pratique ; `dominantExt` (2×UInt64) **peut** tearer → au pire couleur fausse. Mais c'est de l'UB formelle, précisément le genre que `-Ounchecked` + mode Swift 5 rendent indétectable, et qui interdit toute migration Swift 6 propre.

**Fix minimal** : écrire ces quatre champs sous `gTreeLock` dans `finishScan` (ils sont écrits une fois par nœud côté `DirectoryScanner` — coût nul) ; pour le `CommandScanner`, prendre le lock dans `adjustDirectFiles`/`updateDominantExt` ou basculer ces champs en `Atomic` (et `dominantExt` en index 8 bits dans une table d'ExtKey, d'une pierre deux coups pour le tearing).

#### B3 · 🔵 · Threads du scanner sans QoS explicite

[DirectoryScanner.swift:94-100](Sources/MacDirStats/Scanner/DirectoryScanner.swift#L94-L100) : `Thread` créés sans `qualityOfService` → QoS non spécifiée. Douze threads saturant les syscalls peuvent concurrencer le main thread pendant le rendu. `.utility` (ou `.userInitiated` si la vitesse de scan prime) rendrait l'arbitrage explicite. Idem `CommandScanner`.

#### B4 · 🔵 · `cancel()` du `CommandScanner` : semi-annulation

[CommandScanner.swift:71-74](Sources/MacDirStats/Scanner/CommandScanner.swift#L71-L74) : SIGTERM au client `podman/colima ssh`, `markFinished()` immédiat — mais le thread lecteur continue de parser jusqu'à EOF et **écrit dans l'arbre après que l'UI a déclaré le scan terminé** (totaux qui bougent après « Stop »), et le `find` distant lancé sous `sudo` peut survivre à la session selon la config sshd. Fix : fermer le `fileHandleForReading` pour débloquer/terminer la boucle, et considérer `ssh -t` ou un kill explicite du process distant.

#### B5 · ⚪ · `-Ounchecked` + `.swiftLanguageMode(.v5)` : le mauvais endroit pour retirer les filets

[Package.swift:14-19](Sources/../Package.swift#L14-L19) : le commentaire est honnête (le pool manuel « fights strict concurrency »), mais la conséquence est que le code le plus dangereux du projet (arithmétique d'offsets de `FSAttr`, pointeurs bruts) tourne sans bounds checks en release. Le gain d'`-Ounchecked` sur ce type de workload (syscall-bound) est probablement < 5 % — **à mesurer** avec le mode headless avant de le garder. Trajectoire recommandée : cf. [S1](#s1).

### 3.C Résilience et gestion d'erreurs

<a id="c1"></a>
#### C1 · 🟠 · Aucun timeout, aucune annulation sur les `Process` externes

**Où** : [VMProbe.swift:37-48](Sources/MacDirStats/Scanner/VMProbe.swift#L37-L48) (`capture` = `readDataToEndOfFile` bloquant), utilisé par *toutes* les requêtes podman/colima/kubectl.

**Scénarios** : contexte kubectl dont l'API server est injoignable (VPN coupé) → `kubectl get pvc -A` bloque de longues secondes à minutes → la tâche détachée reste suspendue, spinner infini ; « Refresh » **empile** de nouveaux process bloqués ; `stop()`/`loadID` invalide le *résultat* mais ne tue jamais le *process*. Podman machine wedgée → même chose sur le splash (détection) — le splash, lui, est asynchrone, mais les cartes n'apparaissent jamais et aucun message ne l'explique.

**Fix structurel** : un utilitaire unique `ProcessRunner.run(exe, args, timeout:) async throws -> (stdout, stderr, code)` — timeout via `DispatchSourceTimer`/`Task.sleep` + `terminate()` puis `kill(SIGKILL)`, annulation coopérative (`withTaskCancellationHandler` → terminate). Remplacer les 100 % d'appels `capture` par lui. C'est le fix au meilleur ratio robustesse/effort du projet (~2–3 h).

<a id="c2"></a>
#### C2 · 🟠 · Échecs silencieux systémiques

Inventaire :
- [CommandScanner.swift:51](Sources/MacDirStats/Scanner/CommandScanner.swift#L51) : `stderr → nullDevice`, exit code jamais lu. Si la VM n'a pas GNU findutils/`stdbuf` (images busybox/Alpine : `find` sans `-printf`) ou si `sudo` refuse → **scan « réussi » à 0 octet**, aucune distinction d'un volume vide.
- [ScanController.swift:496-546](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L546) : `remove()` retourne `Bool`… ignoré par tous les appelants ([DirectoryListView.swift:219-224](Sources/MacDirStats/Views/DirectoryListView.swift#L219-L224)) → une corbeille qui échoue (volume réseau, permissions) ne produit **aucun feedback**, l'item reste dans la liste sans explication.
- [ContainerController.swift:85-91](Sources/MacDirStats/ViewModel/ContainerController.swift#L85-L91) : `rmi`/`prune` — sortie et code ignorés ; un échec (image utilisée par un conteneur) se manifeste par… rien (le reload réaffiche l'image).
- `jsonArray`/`jsonItems` : tout échec de parsing → `nil` → listes vides, indistinguables d'un état « rien à afficher ».

**Fix** : phase `.failed(String)` sur les contrôleurs + bandeau d'erreur discret ; pour `CommandScanner`, capturer les ~2 Ko de stderr + exit code et les remonter via le backend. Pour `remove`, une alerte sur `false` (le `Bool` existe déjà, il ne manque que le consommateur).

<a id="c3"></a>
#### C3 · 🟡 · Mode K8s : spinner infini sur cluster vide ou accès refusé

[KubernetesResultView.swift:17-24](Sources/MacDirStats/Views/KubernetesResultView.swift#L17-L24) : la condition d'affichage est `controller.pvcs.isEmpty` — pas `state == .loading`. Un cluster sans PVC, un RBAC qui refuse `get pvc`, ou un kubectl absent → « Querying… » **pour toujours**, y compris à `state == .ready`. Fix : brancher sur `state` + vue vide (« Aucun PVC dans ce contexte ») + vue erreur (dépend de C1/C2).

#### C4 · 🔵 · Splash : listes non rafraîchies

[ContentView.swift:411-417](Sources/MacDirStats/Views/ContentView.swift#L411-L417) : volumes lus à l'apparition, VMs/engines/contexts une fois. Brancher un disque USB pendant qu'on est sur le splash ne fait rien. Fix : observer `NSWorkspace.shared.notificationCenter` (`didMountNotification`/`didUnmountNotification`) + bouton refresh discret.

#### C5 · 🔵 · Environnement GUI ≠ shell : `KUBECONFIG` et PATH

`VMProbe.locate` compense intelligemment le PATH réduit des .app pour les *binaires*, mais `KUBECONFIG` (multi-fichiers, colon-separated) n'est pas hérité d'une app lancée par Finder → contexts manquants vs terminal, sans explication. Piste : lire `~/.zshenv`-like est fragile ; a minima documenter, ou offrir un sélecteur de kubeconfig.

#### C6 · ⚪ · Headless : code de sortie toujours 0

`HeadlessScan` imprime les erreurs mais `exit code` reste 0 — gênant pour du scripting/CI (`--scan` sur chemin inexistant « réussit »).

### 3.D Sécurité et opérations destructives

#### D1 · 🟠 · Suppression par chemin reconstruit : fenêtre TOCTOU large

[ScanController.swift:374-394](Sources/MacDirStats/ViewModel/ScanController.swift#L374-L394) + `remove` : le chemin est rebâti depuis un arbre potentiellement **vieux de plusieurs heures** (aucune invalidation FSEvents). Si l'utilisateur (ou un process) a renommé/déplacé des dossiers entre-temps, le chemin peut désigner **un autre contenu** que ce que la liste affiche — et « Delete Permanently » l'efface. Mitigations proportionnées :
1. Avant suppression, re-`stat` et comparer taille agrégée/`fileID` plausibles — au moindre doute, alerte « le disque a changé, relancez le scan » ;
2. Enrichir l'alerte de confirmation avec **ce que le nœud croit supprimer** : « 12 400 fichiers · 48,2 GB · modifié il y a 3 h » (les données sont déjà dans le nœud — l'alerte actuelle ne montre que le nom) ;
3. FSEvents (cf. [S4](#s4)) pour marquer les sous-arbres sales et dégrader les actions dessus.

Le choix corbeille-par-défaut (`trashItem`) est le bon défaut ; « Delete Permanently » a sa confirmation dédiée ✅.

#### D2 · 🔵 · Exécution de binaires localisés par heuristique

`VMProbe.locate` scanne des répertoires connus puis le PATH. Un binaire `podman` malveillant en `/opt/homebrew/bin` serait exécuté — surface réelle faible (l'attaquant qui écrit là a déjà gagné), mais convention : préférer les chemins absolus vérifiés ou `xattr`-check si l'app est un jour distribuée signée/notariée.

#### D3 · ⚪ · Prune volumes = suppression de données potentiellement précieuses

`podman volume prune -f` supprime **tous** les volumes non montés — y compris des bases de données de dev. L'alerte dit bien « can't be undone », mais lister les volumes concernés (déjà connus : `volumes.filter { !$0.inUse }`) rendrait le consentement éclairé.

#### D4 · ⚪ · Distribution

Signature ad-hoc (FDA à re-granter à chaque build — documenté ✅), pas de notarisation, pas d'icône, `com.macdirstats.app` comme bundle id. Rien de bloquant en usage perso ; checklist connue le jour où ça sort du poste.

### 3.E Performance et réactivité UI

#### E1 · 🟠 · `filesIn()` : ré-énumération disque à 10 Hz sur le main thread pendant le scan

[ScanController.swift:344-371](Sources/MacDirStats/ViewModel/ScanController.swift#L344-L371) : le cache n'est peuplé que `phase != .scanning`. Pendant un scan, **chaque tick de 100 ms** reconstruit `visibleRows`, qui ré-ouvre et ré-énumère **sur disque** chaque dossier étendu contenant des fichiers — sur le main thread. Sur SSD local c'est absorbé ; sur un dossier réseau choisi via ⌘O (seed autorisée) ou un gros dossier (100 k fichiers directs), c'est un hitch UI répété × 10/s. Fix : cacher aussi pendant le scan avec invalidation quand `finishScan`/le version bump touche ce nœud (un simple `(count, generation)` par entrée suffit), ou énumérer en tâche détachée avec placeholder.

#### E2 · 🟡 · `sortedChildren` non caché pendant le scan

[ScanController.swift:329-340](Sources/MacDirStats/ViewModel/ScanController.swift#L329-L340) : à chaque tick, tri de chaque nœud étendu (O(n log n) × 10 Hz). Pour un dossier de 50 k enfants (node_modules, maildirs) étendu pendant le scan, ça se sent. Piste : cache versionné même en scan (tri recalculé seulement si `childCount` a bougé — approximation acceptable puisque les tailles bougent de toute façon entre ticks) ou tri partiel (top-N visibles).

#### E3 · 🟡 · `CommandScanner` : propagation ancêtres **par fichier**

[CommandScanner.swift:162-168](Sources/MacDirStats/Scanner/CommandScanner.swift#L162-L168) : chaque ligne fichier remonte toute la chaîne d'ancêtres (atomics + `parent` walk). `find` émet les fichiers d'un même répertoire consécutivement : accumuler `(logical, physical, count)` tant que `parentPath` ne change pas, puis propager une fois — ~10× moins d'opérations, gain direct sur le débit d'ingestion des gros scans VM. Le `DirectoryScanner` fait déjà exactement ça (par répertoire) — c'est une asymétrie d'implémentation, pas un choix.

#### E4 · 🟡 · K8s : usage kubelet séquentiel

[KubernetesController.swift:89-100](Sources/MacDirStats/ViewModel/KubernetesController.swift#L89-L100) : un `kubectl get --raw` **par nœud, en série**. Cluster de 50 nœuds × 0,5 s = 25 s pour remplir les jauges. `withTaskGroup` borné à 6–8 en vol (les kubelets encaissent) + agrégation au fil de l'eau conserve la progressivité en divisant le temps par ~6. Attention à combiner avec C1 (timeout par nœud) sinon un nœud mort bloque sa slot.

#### E5 · 🔵 · `K8sTreemap.computeTiles` recalculé à chaque évaluation du body

[KubernetesResultView.swift:308-311](Sources/MacDirStats/Views/KubernetesResultView.swift#L308-L311) : `let tiles = computeTiles(...)` dans le `GeometryReader` → chaque mouvement de souris (mutation de `hovered`) re-squarifie tout. Volumes en jeu faibles (centaines de PVC max), donc pas de symptôme aujourd'hui — mais c'est l'anti-pattern exact que `TreemapView` évite soigneusement. Memoïser sur `(pvcs, metric, size)` pour l'hygiène et l'exemplarité.

#### E6 · 🔵 · `setSearch` : marche complète de l'arbre sur le main thread

[ScanController.swift:71-92](Sources/MacDirStats/ViewModel/ScanController.swift#L71-L92) : débounce 250 ms ✅, mais la marche (verrou par nœud + `range(of:options:.caseInsensitive)` par nom) est synchrone sur MainActor. À 500 k répertoires, c'est une dizaine à une centaine de ms par frappe validée. Piste : recherche en tâche détachée sur snapshot (les enfants sont déjà snapshotés sous lock) + application du résultat sur MainActor, et comparaison bytes-wise ASCII-insensitive avant de payer `String.range`.

#### E7 · ⚪ · Budget main-thread par tick de scan

À chaque 100 ms : relayout treemap complet + rebuild outline + (1 tick/4) snapshot-tri des extensions. C'est le cœur du parti pris « live » et ça tient sur Apple Silicon avec des arbres normaux. Si un jour ça ne tient plus : cadencer différemment les trois consommateurs (treemap 4 Hz suffit visuellement), et déplacer `TreemapLayout.compute` hors main thread (entrées déjà thread-safe via les snapshots — seule la publication doit revenir sur MainActor).

### 3.F Algorithmes et logique de vues

#### F1 · ⚪ · Squarified treemap : implémentation **correcte**

[TreemapLayout.swift:94-161](Sources/MacDirStats/Views/TreemapLayout.swift#L94-L161) relu pas à pas : critère du pire ratio conforme (Bruls et al.), placement décroissant avec restitution dans l'ordre d'entrée, gardes de dégénérescence (`total<=0`, `side<=0` → ∞), dérive flottante bornée (tuiles ≤ 0 filtrées à la consommation). Les caps (`minSide 5`, `maxDepth 14`) bornent le nombre de tuiles — sain. Le fallback `selectionRect` vers l'ancêtre régionné ([TreemapView.swift:143-152](Sources/MacDirStats/Views/TreemapView.swift#L143-L152)) est une jolie astuce.

<a id="f2"></a>
#### F2 · 🔵 · Sélection à deux têtes désynchronisée par le zoom

`selection: FSNode?` + `selectedRowID: RowID?` doivent être mus ensemble ; or [zoom(into:)](Sources/MacDirStats/ViewModel/ScanController.swift#L557-L563), `zoomOut()` et `resetZoom()` ne touchent que `selection` → après un double-clic de zoom, la liste surligne encore l'ancienne ligne tandis que breadcrumb/treemap sont sur la nouvelle. Symptôme direct du problème I2 (état de navigation éclaté). Fix immédiat : une seule méthode privée `setSelection(_:)` qui maintient les deux. Fix de fond : dériver `selectedRowID` de `selection` (les fichiers sélectionnés étant le seul cas propre à `RowID`).

#### F3 · 🔵 · `hovered` non invalidé au relayout

[TreemapView.swift](Sources/MacDirStats/Views/TreemapView.swift) : après zoom/rescan/suppression, l'overlay hover pointe sur une tuile de l'ancien layout jusqu'au prochain mouvement de souris (rectangle fantôme). Réinitialiser `hovered = nil` dans `recompute`.

#### F4 · 🔵 · La recherche ne couvre que les répertoires

Par construction (les fichiers ne sont pas en mémoire). Le placeholder « Search folders… » l'assume ✅. Deux évolutions possibles : (a) chercher aussi dans les caches `filesIn` des dossiers déjà ouverts (gratuit), (b) mode « recherche profonde » qui relance une traversée dédiée streamée (sans matérialiser l'arbre fichiers). À défaut, une infobulle explicitant la portée évitera des rapports de bug « il ne trouve pas mon fichier ».

#### F5 · ⚪ · Micro-nuances de casse d'extensions

`ExtKey` case-folde l'ASCII seulement ; [DirectoryListView.extDisplay](Sources/MacDirStats/Views/DirectoryListView.swift#L234-L241) utilise `lowercased()` Unicode → pour une extension non-ASCII (`.PDFé`), la clé de couleur de la ligne fichier peut diverger de celle de la légende. Cosmétique, fréquence quasi nulle. Idem : cap `maxFilesPerFolder` trie par `physical` même en métrique logique.

#### F6 · ⚪ · Divers vues

- Seuils de couleur d'usage incohérents : VolumeCard 70/90 %, PieGauge K8s 70/85 % — unifier dans `Theme`.
- `Theme.stableUnit` et `CImage.dangling`/`created` : code mort — supprimer ou exploiter (badge « dangling », tri par âge).
- 16 teintes pour toutes les extensions → collisions dès ~5 types (anniversaires) ; `stableUnit` pourrait justement moduler la luminosité en second niveau de discrimination.
- Multi-fenêtres : `WindowGroup` partage un unique `AppModel` — deux fenêtres se voleraient l'état. « New » est retiré des menus ✅, mais ⌘N système/dock peut encore en ouvrir ; envisager `Window` (unique) plutôt que `WindowGroup`.

### 3.G Kubernetes — spécifiques

- **G1 · 🔵** PVC RWX partagé : rattaché au **premier** pod qui le monte ([rows()](Sources/MacDirStats/ViewModel/KubernetesController.swift#L236-L252), dédup `shown`) — lisible mais trompeur (le pod affiché n'est pas « propriétaire »). Badge « shared ×N » + apparition sous chaque pod avec comptage unique dans les totaux.
- **G2 · 🔵** `stats/summary` du kubelet exige `nodes/proxy` (souvent refusé en RBAC managé) et son avenir est incertain ; le fallback silencieux (jauges absentes) est bien géré ✅. Pistes d'enrichissement : `kubectl top`/metrics-server, CSI volume health, ou l'API `VolumeAttributesClass`.
- **G3 · ⚪** Hors périmètre actuel : VolumeSnapshots (souvent la vraie source de coût), volumes éphémères génériques, quotas par StorageClass. Autant d'extensions naturelles du mode.

### 3.H Containers — spécifiques

- **H1 · 🟡** `ContainerEngine.Kind.docker` n'est **jamais détecté** ([ContainerProbe.detect](Sources/MacDirStats/Scanner/ContainerEngine.swift#L62-L69) ne sonde que podman) : enum trompeuse, et les utilisateurs Docker Desktop/colima-docker n'ont pas le mode. Détection : `docker info --format json` avec timeout (cf. C1) ; attention aux formats JSON docker ≠ podman (tailles en strings « 1.2GB » côté docker CLI — le parseur actuel les enverrait à 0 silencieusement).
- **H2 · 🔵** Dépendance aux champs `RawSize`/`RawReclaimable` de `podman system df` : selon les versions, présence/casse varient ; le parsing défensif retombe sur 0 **sans signal**. Ajouter un garde « df incohérent » (Σ tailles = 0 alors que images.count > 0 → bannière).
- **H3 · ⚪** `podman ps --size` est coûteux côté démon sur de gros overlays — acceptable ici, à savoir si le mode devient auto-rafraîchissant.

### 3.I Outillage, qualité, hygiène

- **I1 · 🟠 — Zéro test automatisé**, alors que le projet regorge de pur-fonctions testables : `TreemapLayout.squarify` (propriétés : Σ aires = aire cible ± ε, aucun chevauchement, ordre préservé), `ExtKey` (fuzz bytes → jamais de crash, idempotence casse ASCII), `CommandScanner.parse` (golden lines + noms hostiles), `K8sQueries.parseQuantity`, `Format.bytes`, et surtout **le test d'or de cet audit** : fixture générée (sparse/hardlink/symlink/`\n`) + scan headless vs `du -skl`, et fixture+DMG vs `du -skx` une fois A1 corrigé. Un target de tests swift-testing + `swift test` en CI GitHub Actions macOS ≈ une demi-journée, rendement énorme.
- **I2 · ⚪** Repo propre (le `.app` n'est **pas** tracké — vérifié), mais la feature recherche vit non commitée dans le working tree : à committer pour borner les diffs.
- **I3 · ⚪** `bundle.sh` : `--options runtime` tenté puis fallback sans — OK pour du local ; noter que hardened runtime + get-task-allow ≠ debuggable, d'où le fallback, mais le `|| true` final masquerait un échec total de signature.
- **I4 · ⚪** Pas de logging structuré (`os.Logger`) : les diagnostics de terrain (pourquoi ce scan est vide ?) n'ont aucune trace à exploiter — à introduire en même temps que C2.

---

## 4. Invariants fondamentaux — bilan formel

| Invariant | Statut | Notes |
|---|---|---|
| **Conservation** : `root.agg* = Σ directFiles*` de tous les nœuds scannés | ✅ | Propagation atomique correcte ; suppression : ancêtres ajustés ✅ mais `extStats` ([A6](#a6)) et `dirCount` ([A7](#a7)) divergent. |
| **Complétude finale** : `agg(n) = direct(n) + Σ agg(enfants)` en fin de scan | ✅ | Vérifié par construction + fixture. En cours de scan : `agg` ne sur-estime jamais (les contributions n'arrivent qu'une fois) — bonne propriété. |
| **Unicité de comptage** : chaque bloc disque compté ≤ 1 fois | ❌ | Montages traversés ([A1](#a1)), hardlinks par lien ([A3](#a3), assumé), clones APFS ([A4](#a4)). |
| **Vivacité** : tout nœud atteignable a une chaîne `parent` valide | ❌ | Rompu par `remove(directory:)` pour les descendants retenus ([B1](#b1)). |
| **Publication sûre** : un nœud publié est entièrement initialisé | ❌ | `directFiles*`/`dominantExt` écrits après publication, hors verrou ([B2](#b2)). |
| **Terminaison du pool** : le scan se termine ssi plus aucun travail | ✅ | Comptage `outstanding` prouvé correct ; annulation propre côté local. |
| **Cohérence navigation** : liste, breadcrumb et treemap désignent le même nœud | ❌ (partiel) | `zoom/zoomOut/resetZoom` ne synchronisent pas `selectedRowID` ([F2](#f2)). |
| **Idempotence rescan/goHome** : tout état dérivé réinitialisé | ✅ | `startBackend`/`goHome` purgent caches, recherche, sélection, chemins — vérifié exhaustivement. |
| **Fidélité UI pendant scan** : proportions affichées = proportions vraies | ⚠️ | Vrai entre éléments scannés ; magnitudes renormalisées trompeuses ([A9](#a9)). |
| **Toute défaillance externe est observable par l'utilisateur** | ❌ | Échecs `Process`, suppressions, parsing : silencieux ([C1](#c1)–[C3](#c3)). |

---

## 5. Axes stratégiques (au-delà des fixes)

<a id="s1"></a>
### S1 · Trajectoire Swift 6 / sûreté sans sacrifier le pool manuel

Le pool de threads manuel est **le bon choix** ici (contrôle du LIFO, des buffers réutilisés, de la localité) — inutile de le remplacer par des actors qui sérialiseraient l'ingestion. La trajectoire compatible strict-concurrency :
1. Encapsuler l'état partagé mutable dans `Mutex<T>` (Synchronization, dispo macOS 15) : `Mutex<[WorkItem]>` + condition, `Mutex<[ExtKey: ExtStat]>` — types `Sendable` prouvés ;
2. Régler B2 (publication complète avant visibilité) ;
3. `FSNode: @unchecked Sendable` avec un commentaire d'invariant *vrai* (tout champ mutable protégé par lock/atomic) ;
4. Passer `.swiftLanguageMode(.v6)`, mesurer `-O` vs `-Ounchecked` en headless (parie : indistinguable, syscall-bound) et retirer `-Ounchecked`.
Bénéfice : le compilateur devient le harnais de non-régression concurrence pour toutes les évolutions futures.

<a id="s2"></a>
### S2 · Mutations post-scan : passer de « mutation en place » à « invalidation »

`remove()` fait de la chirurgie en place (soustractions, détachements, caches) sur une structure conçue pour l'append concurrent — c'est de là que viennent B1/A6/A7. Paradigme alternatif : la suppression **réussie** marque le sous-arbre parent « sale » et déclenche un re-scan ciblé de ce seul répertoire (le scanner sait déjà tout faire : c'est une seed). Coût : un scan local de sous-arbre (ms). Gain : plus aucune comptabilité manuelle, plus d'UAF possible, et la voie est ouverte pour…

<a id="s4"></a>
### S3 · FSEvents : de l'instantané au tableau de bord vivant

Un stream FSEvents sur les seeds pendant que le résultat est affiché : marquer les répertoires touchés, badge « le disque a changé », re-scan incrémental des sous-arbres sales (même mécanique que S2). C'est le différenciateur produit qui manque à tous les WinDirStat-like, et l'architecture actuelle (seeds, arbre live, re-scan par nœud) y est étonnamment bien prédisposée.

### S4 · Mode « exact » vs mode « responsabilité »

Aujourd'hui l'app mesure la *responsabilité* (hardlinks par lien, clones pleins, montages traversés). Formaliser deux modes de comptage : **Exact disque** (dédup hardlinks A3, private size clones A4, borné au volume A1 — matche `df`) et **Attribution** (comportement actuel, documenté). C'est une décision de produit qui résout d'un coup la classe entière d'écarts « pourquoi ça ne matche pas Finder ».

### S5 · Treemap au niveau fichier (optionnel, budget RAM maîtrisé)

Le README l'évoque. Voie économe compatible avec le design actuel : stockage **colonnaire par répertoire** (un blob compact `[(nameOffset, logical, physical, extIndex)]` + arène de noms) rempli à la volée uniquement pour les répertoires dont les fichiers pèsent plus que le seuil de tuile visible — l'énumération on-demand existe déjà (`filesIn`), il manque la persistance compacte et l'intégration au layout. Budget : ~24 octets/fichier affiché, activable par un toggle « détail fichiers ».

### S6 · Backends comme plugins d'un contrat enrichi

`ScanBackend` gagnerait trois membres pour absorber C1/C2 proprement : `var failure: BackendFailure? { get }`, `func diagnostics() -> String`, et une notion de source (`host | vm(machine) | remote`). Ensuite, de nouveaux backends deviennent triviaux : SSH générique (serveurs), `tar`/archives, Time Machine (`tmutil`), autre Mac via `ssh + find` (le `CommandScanner` est déjà 90 % du travail).

---

## 6. Plan d'action priorisé

### Quick wins (≤ ½ journée chacun, gains immédiats)

| Prio | ID | Action | Effort |
|---|---|---|---|
| 1 | [A2](#a2) | Corriger l'ordre de parsing `ATTR_CMN_ERROR` | 30 min |
| 2 | [B1](#b1) | Garde-fous `remove()` (reset zoom/sélection/expanded sur descendance) + `parent` en `unowned` safe | 1 h |
| 3 | [A1](#a1) | `ATTR_DIR_MOUNTSTATUS` + skip mount points non-seed | 1–2 h |
| 4 | [C1](#c1) | `ProcessRunner` avec timeout + annulation, adopté partout | 2–3 h |
| 5 | [C2](#c2)/[C3](#c3) | Phase `.failed` + bandeau erreur ; état vide K8s ; consommer le `Bool` de `remove` | 2 h |
| 6 | [F2](#f2)/[F3](#f3) | Unifier la sélection ; invalider `hovered` au relayout | 45 min |
| 7 | [E1](#e1) | Cache `filesIn` pendant le scan | 1 h |
| 8 | [B2](#b2) | Publication complète des nœuds sous verrou | 1 h |
| 9 | I1 | Suite de tests : squarify (propriétés), parse VM, fixture `du -skl` automatisée | ½ j |

### Deuxième vague (structurant)

[E3](#e3) batch par parent dans CommandScanner → [E4](#e4) usage K8s parallèle → [A6](#a6)/[A7](#a7) cohérence post-suppression → [A11](#a11) framing NUL → [H1](#h1) support Docker → [A9](#a9) tuile « non exploré » → [S1](#s1) migration Swift 6 → [A3](#a3)/[A4](#a4) mode exact.

### Fond de roadmap

[S2](#s2) invalidation-plutôt-que-mutation → [S3](#s4) FSEvents live → [S5](#s5) détail fichiers dans le treemap → [S6](#s6) backends pluggables → distribution (icône, notarisation).

---

## 7. Récapitulatif des findings

| ID | Sév. | Domaine | Résumé |
|---|---|---|---|
| A1 | 🟠 | Exactitude | Points de montage traversés — swap/Preboot/externes/DMG sur-comptés (prouvé) |
| A2 | 🔴 | Robustesse | `ATTR_CMN_ERROR` parsé au mauvais offset — corruption/OOB sur entrées en erreur |
| A3 | 🟡 | Exactitude | Hardlinks comptés par lien (assumé) — proposer dédup optionnelle |
| A4 | 🟡 | Exactitude | Clones APFS non déduits — piste `ATTR_CMNEXT_PRIVATESIZE` |
| A5 | 🔵 | Exactitude | `getattrlistbulk` = −1 silencieux — troncature invisible |
| A6 | 🔵 | Intégrité | Panneau types non ajusté après suppression |
| A7 | 🔵 | Intégrité | Compteur dossiers figé après suppression |
| A8 | 🔵 | Fidélité | Couleur de tuile agrégée = fichiers directs seulement |
| A9 | 🔵 | Fidélité | Renormalisation trompeuse du treemap en cours de scan |
| A10 | ⚪ | UX | Base 1024 étiquetée KB/MB (≠ Finder) |
| A11 | 🔵 | Exactitude | Scanner VM : noms avec `\n` cassent le framing — passer en NUL |
| A12 | 🔵 | Exactitude | K8s : nuances `used`/quantités (suffixe milli) |
| B1 | 🔴 | Mémoire | UAF `unowned(unsafe) parent` après suppression d'un ancêtre du zoom/sélection |
| B2 | 🟠 | Concurrence | `directFiles*`/`dominantExt` publiés puis écrits hors verrou (tearing possible) |
| B3 | 🔵 | Concurrence | Threads sans QoS explicite |
| B4 | 🔵 | Concurrence | Annulation VM partielle (écritures post-« finished », find distant survivant) |
| B5 | ⚪ | Stratégie | `-Ounchecked` + Swift 5 : filets retirés là où ils protègent le plus |
| C1 | 🟠 | Résilience | Aucun timeout/annulation sur les `Process` (kubectl/podman) — spinners infinis |
| C2 | 🟠 | Résilience | Échecs silencieux systémiques (stderr, exit codes, remove, prune) |
| C3 | 🟡 | Résilience | K8s : spinner permanent sur cluster vide/RBAC refusé |
| C4 | 🔵 | Résilience | Splash non rafraîchi (montages/VMs) |
| C5 | 🔵 | Résilience | `KUBECONFIG` non hérité en GUI — contexts manquants inexpliqués |
| C6 | ⚪ | Outillage | Headless : exit code toujours 0 |
| D1 | 🟠 | Intégrité | Suppression par chemin périmé (TOCTOU) — confirmation sans contexte |
| D2 | 🔵 | Sécurité | Binaires localisés par heuristique PATH |
| D3 | ⚪ | Sécurité | Prune volumes sans liste des victimes |
| D4 | ⚪ | Distribution | Signature/notarisation/icône |
| E1 | 🟠 | Perf UI | `filesIn` ré-énumère le disque à 10 Hz sur main thread pendant le scan |
| E2 | 🟡 | Perf UI | Tris répétés des enfants pendant le scan |
| E3 | 🟡 | Perf | CommandScanner : propagation par fichier au lieu de par lot |
| E4 | 🟡 | Perf | K8s : requêtes kubelet séquentielles |
| E5 | 🔵 | Perf UI | K8sTreemap recalculé à chaque hover |
| E6 | 🔵 | Perf UI | Recherche synchrone sur main thread |
| E7 | ⚪ | Perf UI | Budget main-thread par tick — pistes de cadencement |
| F1 | ⚪ | Algo | Squarify : conforme et robuste ✅ |
| F2 | 🔵 | UX | Zoom ne synchronise pas la sélection de liste |
| F3 | 🔵 | UX | Hover fantôme après relayout |
| F4 | 🔵 | UX | Recherche limitée aux dossiers (assumé, à outiller) |
| F5 | ⚪ | Détail | Casse d'extensions ASCII vs Unicode, cap fichiers par métrique physique |
| F6 | ⚪ | Détail | Seuils incohérents, code mort, 16 teintes, multi-fenêtres |
| G1 | 🔵 | K8s | PVC partagés rattachés à un seul pod |
| G2 | 🔵 | K8s | Dépendance `nodes/proxy` + stats/summary — fallbacks possibles |
| G3 | ⚪ | K8s | Snapshots/éphémères hors périmètre |
| H1 | 🟡 | Containers | Docker jamais détecté malgré l'enum |
| H2 | 🔵 | Containers | Champs `df` podman version-dépendants → zéros silencieux |
| H3 | ⚪ | Containers | `ps --size` coûteux si auto-refresh un jour |
| I1 | 🟠 | Qualité | Zéro test — cibles à très haut rendement identifiées |
| I2–I4 | ⚪ | Hygiène | Diff non commité, `|| true` de codesign, pas de logging structuré |

---

*Audit réalisé par lecture exhaustive du code et vérification empirique sur macOS (Darwin 25.5) — les findings A1, A2 (via man page) et l'exactitude `du -skl` ont été prouvés par l'expérience, pas seulement par l'analyse statique.*
