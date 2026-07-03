# Audit opérationnel & expérience quotidienne — MacDirStats

> **Date** : 2026-07-02 · **Complément de** : [AUDIT.md](AUDIT.md) (audit code/algorithmique).
> **Angle** : l'app vue depuis la chaise de l'utilisateur, jour après jour. Chaque parcours (installation → scan → exploration → nettoyage → rescan → modes VM/containers/K8s) est déroulé systématiquement contre le code source ; chaque friction, comportement surprenant ou impasse est tracé jusqu'à sa cause dans le code.
> **Méthode** : analyse exhaustive du code + vérifications par grep (chaque « absent » ou « jamais appelé » ci-dessous a été prouvé, pas supposé).

---

## 0. Résumé exécutif

Le produit est **excellent dans sa boucle centrale de 3 minutes** (lancer un scan, regarder le treemap se remplir, comprendre où est l'espace) et **fragile dès qu'on en sort** : nettoyer sérieusement (suppressions synchrones qui gèlent l'UI, pas de ⌘⌫, pas de multi-sélection), revenir le lendemain (aucune persistance de contexte, données périmées sans indicateur), ou expliquer ses chiffres (trois nombres différents entre le scan, la carte volume et le Finder, sans réconciliation).

Découvertes structurantes de cet audit :

| Constat | Gravité quotidienne |
|---|---|
| **Le zoom arrière du treemap n'existe pas dans l'UI** — `zoomOut()`/`resetZoom()` ne sont appelés nulle part (grep), le README documente un bouton « ↖︎ » fantôme. Une fois zoomé, seuls le breadcrumb ou un re-zoom permettent d'en sortir. | 🔴 Chaque session |
| **Supprimer un gros dossier gèle l'application** — `remove()` s'exécute sur le MainActor ([ScanController.swift:496-546](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L546)) : beachball garanti sur un `node_modules` de 5 Go en suppression définitive. | 🔴 Chaque nettoyage |
| **Supprimer pendant un scan actif corrompt les totaux** — les workers continuent d'alimenter les ancêtres via le sous-arbre détaché ; rien ne désactive les actions destructives pendant `phase == .scanning`. | 🟠 Occasionnel mais invisible |
| **Trois fonctionnalités terminées sont inaccessibles depuis l'UI** : scan « Containers storage » des VM, scan multi-volumes agrégé, mode Docker (enum). Du travail fini qui ne rend service à personne. | 🟠 |
| **Aucune navigation clavier, aucun QuickLook, aucune accessibilité** — grep : zéro `onKeyPress`/`onMoveCommand`/`onDeleteCommand`/`accessibility*`/`QLPreview` dans tout le projet. L'app est 100 % souris. | 🟠 Chaque session |
| **L'écart de chiffres n'est expliqué nulle part** — purgeable, snapshots APFS, corbeille non vidée, base 1024 vs Finder : les quatre causes de « pourquoi ça ne matche pas ? » sont toutes présentes et aucune n'est adressée dans l'UI. | 🟠 Première question de tout utilisateur |

---

## 1. Parcours J1 — Installation et premier lancement

### J1.1 · 🟡 · Distribution : compilation obligatoire, copie impossible

Seule voie d'installation : cloner + `./bundle.sh` (toolchain Xcode 16 requise). Pas de binaire de release, pas de formule Homebrew, pas de DMG. Conséquence moins évidente : l'app **ne peut pas être partagée** — signée ad-hoc, elle sera bloquée par Gatekeeper sur toute autre machine (pas de notarisation), et la quarantaine + app translocation rendront le comportement erratique. Pour un outil dont la cible naturelle est « le collègue dont le disque est plein », c'est un mur. *Piste : release GitHub signée Developer ID + notarisée, ou cask Homebrew.*

### J1.2 · 🔵 · Icône Dock générique

`bundle.sh` ne déclare aucun `CFBundleIconFile` et n'embarque aucun `.icns` : le Dock, le Cmd-Tab et le Finder affichent l'icône d'exécutable générique. Pour une app « vivid design », c'est la première impression, à chaque lancement. *Une icône AppIcon (le camembert du splash ferait l'affaire) = 30 min.*

### J1.3 · 🟠 · Onboarding Full Disk Access incomplet — la boucle du Relaunch inutile

Le bandeau FDA ([ContentView.swift:68-103](Sources/MacDirStats/Views/ContentView.swift#L68-L103)) dit : « After enabling it in Settings, choose Relaunch ». Mais FDA ne se *demande* pas : l'app n'apparaît dans la liste Réglages → Confidentialité → Accès complet au disque **que si l'utilisateur l'y ajoute manuellement via « + »** — étape jamais mentionnée. Parcours réel du novice : Open Settings → ne trouve pas MacDirStats dans la liste → revient → Relaunch → rien n'a changé → re-bandeau. Trois autres nuances :
- le bandeau s'affiche aussi sur les routes **Containers/Kubernetes/VM** où FDA n'a aucun rôle — bruit ;
- `fdaBannerDismissed` est définitif : celui qui ferme le bandeau puis scanne son disque avec 40 000 « skipped » n'aura plus jamais le lien entre les deux ;
- après un scan à fort taux d'erreurs sans FDA, **rien** ne suggère la cause (cf. J2.2).

*Fix : bandeau avec mini-étapes (« ajoutez l'app avec + puis relancez »), drag-source de l'app vers la fenêtre Réglages (pattern connu), bandeau contextuel re-proposé quand `errorCount` explose sans FDA.*

### J1.4 · 🔵 · Info.plist sans usage descriptions TCC

Aucune clé `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription` dans le plist généré par `bundle.sh`. Les prompts TCC s'affichent quand même (app non sandboxée) mais **sans la phrase d'explication** — des dialogues systèmes nus, en rafale (cf. J2.1), pour une app qui demande précisément beaucoup de confiance.

### J1.5 · ⚪ · Pas d'About utile, pas de version, pas de mise à jour

`CFBundleShortVersionString` figé à « 1.0 », aucun About custom, aucun canal de mise à jour (Sparkle ou « check GitHub releases »). Impossible pour un utilisateur de savoir quel build il exécute — gênant dès le premier bug report.

**Positifs J1** : `bundle.sh` documente le vrai problème du cdhash ad-hoc vs TCC (rare et précieux) ; taille minimale de fenêtre raisonnable (900×560) ; app-quit-on-close cohérent avec un outil mono-tâche.

---

## 2. Parcours J2 — Le premier scan d'un disque

### J2.1 · 🟠 · Sans FDA : la cascade de prompts TCC pendant le scan

Scanner `/Users/moi` sans FDA déclenche séquentiellement les prompts système Bureau, Documents, Téléchargements, (photos, etc.) — **pendant** que le treemap bouge et que les stats défilent. L'utilisateur répond au hasard, chaque refus devient des erreurs silencieuses. Le scan est si rapide que les prompts arrivent *après* avoir été déjà comptés en erreur pour les premiers répertoires touchés. *Piste : pré-vol optionnel (toucher Desktop/Documents/Downloads avant de lancer les workers, pour sérialiser les prompts), ou pousser FDA plus fort en amont (J1.3).*

### J2.2 · 🟠 · « skipped » : un chiffre mort

[ContentView.swift:301-303](Sources/MacDirStats/Views/ContentView.swift#L301-L303) : le compteur d'erreurs s'affiche (« 41 231 skipped ») mais : aucun clic, aucune liste des chemins échoués, aucune distinction EPERM/EIO/disparition du volume, aucun lien vers FDA. L'utilisateur ne peut **rien faire** de cette information, alors que dans 95 % des cas la réponse est « accordez FDA et relancez ». *Fix : mémoriser les N premiers chemins en échec par errno (le scanner les a, il les jette), popover au clic sur le chip, CTA FDA si dominante EPERM.*

### J2.3 · 🟡 · App Nap non gérée : le scan d'arrière-plan qui semble gelé

Grep : aucun `ProcessInfo.beginActivity` dans le projet. Parcours réel : l'utilisateur lance le scan du disque, bascule sur Slack pendant que ça tourne, revient — macOS a pu napper le process (timers throttlés, QoS abaissée) : la fenêtre affiche des stats figées qui « sautent » au retour, et le scan lui-même a été ralenti alors que c'est précisément sa raison d'être. *Fix (4 lignes) : `beginActivity(options: [.userInitiated], reason: "Disk scan")` à `startBackend`, `endActivity` à la fin/annulation. Ne pas empêcher la veille système (choix respectueux), seulement le nap.*

### J2.4 · 🟡 · Fermer la fenêtre pendant un scan = quit sec sans confirmation

`applicationShouldTerminateAfterLastWindowClosed → true` + aucune interception : un ⌘W réflexe à 80 % d'un scan de 4 To tue tout, sans dialogue. Même chose pendant une **suppression** en cours (là c'est plus gênant : `trashItem` interrompu à mi-parcours d'une arborescence). *Fix : confirmation si `phase == .scanning` ou suppression en vol.*

### J2.5 · 🟡 · Cibles mouvantes : misclicks pendant le scan

Deux mécanismes se combinent : la liste **re-trie à chaque tick de 100 ms** ([sortedChildren](Sources/MacDirStats/ViewModel/ScanController.swift#L329-L340) sans cache pendant le scan) et le treemap **relayoute à 10 Hz**. Cliquer sur une ligne/tuile pendant le scan sélectionne régulièrement l'élément qui vient de prendre sa place — et le menu contextuel s'ouvre alors sur le mauvais dossier, avec « Move to Trash » deux items plus bas. Combiné à J4.4 (le delete pendant scan est permis), c'est le scénario du dossier trashé par erreur. *Pistes : hystérésis de tri (ne réordonner que si l'écart dépasse x %), gel du reflow au survol, et gating des actions destructives pendant le scan (cf. J4.4).*

### J2.6 · 🔵 · Volume éjecté / débranché en plein scan

Les `open()` échouent, `errorCount` grimpe, le scan « se termine » normalement avec des totaux partiels — aucune bannière « le volume a disparu ». Croisé avec J2.2, l'utilisateur voit juste un disque bizarrement vide.

**Positifs J2** : vitesse réelle (validée : ~400 k fichiers/s en debug sur la fixture) ; Stop instantané ; stats strip lisible ; le remplissage live est spectaculaire et fonctionne comme promis ; getattrlistbulk ne déclenche **pas** le téléchargement des fichiers iCloud dataless (vérifié dans la conception — force du choix syscall).

---

## 3. Parcours J3 — Explorer les résultats

### J3.1 · 🟠 · Zéro clavier : une app 100 % souris

Grep : aucun `onMoveCommand`, `onKeyPress`, `onDeleteCommand`, `focusable` ; la `List` n'utilise pas la sélection native (tout passe par `onTapGesture`). Conséquences quotidiennes : pas de ↑/↓ pour parcourir, pas de ←/→ pour plier/déplier, pas de ⏎ pour ouvrir, pas de ⌘⌫ pour trasher (cf. J4.2), pas d'Échap pour sortir de la recherche ou du zoom. Pour l'utilisateur cible (dev senior), c'est LA friction récurrente. *Fix structurant : passer la liste sur `List(selection:)` native + `.contextMenu(forSelectionType:)` — on gagne d'un coup clavier, multi-sélection (J4.2) et menus contextuels standard.*

### J3.2 · 🟠 · Pas de QuickLook

« C'est quoi ce fichier de 8 Go ? » → aujourd'hui : Reveal in Finder → espace → revenir. La barre espace avec `QLPreviewPanel` (ou `.quickLookPreview`) est le geste n° 1 de tri visuel de gros fichiers (vidéos, archives, dmg). Absent (grep).

### J3.3 · 🟡 · Le hover du treemap n'affiche pas le chemin

[HoverLabel](Sources/MacDirStats/Views/TreemapView.swift#L240-L264) : icône + **nom** + taille. Sur un disque système, il y a des dizaines de tuiles `Caches`, `Data`, `Resources`, `node_modules` — impossible de savoir *laquelle* on survole sans cliquer (ce qui déplace la sélection et déplie l'arbre, effet de bord pour une simple question). *Fix : chemin relatif au zoom root dans le label (la remontée `parent` existe déjà : `zoomPath`).*

### J3.4 · 🟡 · Pas de menu contextuel sur le treemap

Grep `contextMenu` : liste, images containers, PVC — **pas le treemap**. Le flux naturel « je vois la grosse tuile → clic droit → Corbeille / Reveal in Finder » n'existe pas ; il faut cliquer (sélection), retrouver la ligne dans la liste, et faire le clic droit là-bas. Deux fois plus de gestes pour l'action principale du produit.

### J3.5 · 🔴 · Impossible de dézoomer le treemap (et le README décrit un bouton qui n'existe pas)

Prouvé par grep : `zoomOut()` et `resetZoom()` ([ScanController.swift:581-593](Sources/MacDirStats/ViewModel/ScanController.swift#L581-L593)) n'ont **aucun appelant**. Le README (§ Using the UI) documente « the ↖︎ button zooms out » — bouton inexistant dans le code. Seule issue réelle : cliquer un segment du breadcrumb (pas évident, et le breadcrumb scrolle). Manquent : double-clic sur le fond, ⌘↑/Échap, bouton explicite. C'est un cul-de-sac d'UI sur le geste le plus fréquent après le zoom lui-même. *Fix : 20 lignes + corriger le README.*

### J3.6 · 🟡 · Troncature silencieuse à 2 000 fichiers par dossier

[maxFilesPerFolder](Sources/MacDirStats/ViewModel/ScanController.swift#L309) : un dossier de 8 000 fichiers n'en montre que les 2 000 plus gros, **sans aucune mention**. L'utilisateur qui compare avec le Finder conclut à un bug de comptage (le total du dossier, lui, est juste). *Fix : ligne terminale « … et 6 000 fichiers de moins de X MB (Y GB) ».*

### J3.7 · 🔵 · Un seul ordre de tri, pas de colonnes

Toujours par taille décroissante. Pas de tri par nom (retrouver un dossier connu), par nombre de fichiers (chasser les millions de petits fichiers — cas `node_modules`/caches où la *taille* n'est pas le problème), ni par date (identifier le vieux). Pas de colonne « % du parent » — la barre relative aux siblings la remplace partiellement mais sans valeur lisible.

### J3.8 · 🔵 · Recherche : sorties et retours manquants

Pas d'Échap pour effacer/sortir (il faut viser le petit ⊗), pas de compteur « N résultats », et en mode recherche les **fichiers disparaissent** de la liste (l'arbre élagué ne montre que des dossiers) sans explication — combiné au fait, assumé, que la recherche ne couvre que les noms de dossiers ([AUDIT.md F4](AUDIT.md)). Nuance de plus : la comparaison `range(of:.caseInsensitive)` n'est pas insensible à la normalisation Unicode — un « é » NFC tapé peut rater un nom NFD hérité de HFS+/outils divers ; ajouter `.diacriticInsensitive`+`.widthInsensitive` ou normaliser.

### J3.9 · 🔵 · Fenêtre anonyme, mono-fenêtre de fait

Aucun `navigationTitle`/titre de fenêtre (grep) : dans Mission Control / Cmd-Tab, la fenêtre s'appelle « MacDirStats » quel que soit le scan. Et le `WindowGroup` partage l'unique `AppModel` : une deuxième fenêtre (⌘N système, clic Dock) afficherait/écraserait le même état — passer à `Window` (scène unique) et titrer `rootName`.

### J3.10 · 🔵 · Splitters non persistés

`HSplitView`/`VSplitView` (legacy, sans autosave) : la géométrie des trois panneaux est à re-régler **à chaque lancement**. Persister les fractions dans `@AppStorage` (ou migrer vers `NavigationSplitView` pour le panneau principal).

**Positifs J3** : breadcrumb cliquable pilotant les deux panneaux (excellent) ; tooltip pédagogique On disk/Logical (rare d'être aussi bien expliqué) ; aller-retour liste↔treemap (`reveal`) vraiment bidirectionnel ; spotlight par type de fichier original et utile ; virtualisation de la liste solide.

---

## 4. Parcours J4 — Nettoyer (le cœur d'usage du produit)

### J4.1 · 🔴 · Suppressions synchrones sur le main thread : beachball garanti

`remove(directory:/file:)` est sur `@MainActor` et appelle `FileManager.removeItem`/`trashItem` **en synchrone** ([ScanController.swift:496-546](Sources/MacDirStats/ViewModel/ScanController.swift#L496-L546)). Suppression définitive d'un dossier d'1 M de fichiers : plusieurs dizaines de secondes de beachball, fenêtre « ne répond pas », aucun progrès, aucune annulation. Corbeille inter-volume (dossier sur disque externe → corbeille = copie) : pire. C'est le geste central du produit dans son pire état. *Fix : exécuter en `Task.detached`, item marqué « suppression… » (opacité), résultat appliqué au retour — l'infrastructure d'ajustement des agrégats existe déjà, elle est juste appelée du mauvais thread.*

### J4.2 · 🟠 · Pas de ⌘⌫, pas de multi-sélection : le nettoyage de masse est laborieux

Grep `keyboardShortcut` : **deux** raccourcis dans toute l'app (⌘O, ⌘F). Ni ⌘⌫ (corbeille — standard Finder), ni ⌘R (rescan), ni ⌘↑ (dézoom). Et la sélection est strictement simple : nettoyer 12 vieux dmg dans Downloads = 12 × (clic droit → Move to Trash). La refonte `List(selection:)` de J3.1 débloque les deux d'un coup.

### J4.3 · 🟡 · Corbeille pleine ≠ espace libéré : la confusion n'est pas désamorcée

Après « Move to Trash », l'app décrémente ses totaux — mais le disque, lui, n'a **rien** libéré tant que la corbeille n'est pas vidée. L'utilisateur vérifie dans Finder/À propos de ce Mac : espace inchangé → « l'app ment ». Aucun message. *Fix : compteur de session « Déplacé vers la corbeille : 38,2 GB — [Vider la corbeille] » (le vidage se scripte via `NSWorkspace` ou en ouvrant la corbeille).* Ce même compteur de session (« libéré depuis le scan ») est le feedback de récompense qui manque au flux nettoyage.

### J4.4 · 🟠 · Supprimer pendant un scan actif : autorisé, et ça corrompt les totaux

Le menu contextuel n'est conditionné que par `isHostScan`, pas par `phase`. Or pendant le scan, `remove(directory:)` soustrait l'agrégat *courant* du sous-arbre puis le détache — mais les workers ont encore des `WorkItem` en file **dans ce sous-arbre** : leurs contributions futures remontent la chaîne `parent` (toujours pointée vers l'arbre vivant) et regonflent des ancêtres déjà « soldés ». Résultat : totaux définitivement faux (sur-comptés), plus une rafale d'erreurs ENOENT sur les chemins trashés. S'ajoute au risque de misclick de J2.5 et à l'UAF [B1 d'AUDIT.md](AUDIT.md). *Fix minimal : désactiver Trash/Delete tant que `phase == .scanning` (une ligne de garde + item grisé) — la version ambitieuse étant l'invalidation-rescan de [S2](AUDIT.md).*

### J4.5 · 🔵 · « Remettre » depuis la corbeille : l'app ne le voit jamais

Put Back dans le Finder → le fichier revient, l'arbre de l'app reste amputé jusqu'au rescan manuel. Cohérent avec l'absence de FSEvents ([S3 d'AUDIT.md](AUDIT.md)) ; a minima, le compteur de session de J4.3 rend le modèle mental explicite (« ce que l'app croit »).

### J4.6 · 🟠 · Échec de suppression : rien ne se passe (renvoi C2)

Le `Bool` de `remove()` est ignoré par tous les appelants ([DirectoryListView.swift:61-67, 219-224](Sources/MacDirStats/Views/DirectoryListView.swift#L61-L67)) : corbeille indisponible (réseau), permissions, fichier verrouillé → l'item **reste dans la liste sans aucun feedback**. L'utilisateur re-clique, re-rien. Déjà classé C2 dans l'audit code ; au niveau UX c'est le trou le plus déroutant du flux principal.

**Positifs J4** : corbeille par défaut et suppression définitive séparée avec confirmation dédiée — la hiérarchie de danger est la bonne ; la mise à jour instantanée treemap+liste+totaux après suppression est très satisfaisante (quand elle marche).

---

## 5. Parcours J5 — Rescan, sessions longues, lendemains

### J5.1 · 🟡 · Rescan = tout perdre

Le cycle réel de nettoyage est : scanner → creuser jusqu'à `~/Library/Caches/org.Truc` → supprimer → **rescanner pour vérifier** → … et se retrouver à la racine, zoom et dépliages perdus, à re-naviguer 6 niveaux. `startBackend` réinitialise tout (correct pour l'intégrité), mais rien ne re-résout le contexte. *Fix : mémoriser `zoomPath`/sélection en *chemins* (les nœuds meurent, les chemins survivent) et les re-résoudre à la fin du rescan — `path(for:)` et la structure seed existent déjà.*

### J5.2 · 🟡 · Données périmées sans aucun indicateur

L'app reste ouverte des heures (c'est un dashboard qu'on garde) : aucun horodatage « scanné il y a 3 h », aucune détection de dérive (FSEvents absent), et les actions Trash/Delete opèrent sur des chemins reconstruits depuis cet état périmé ([TOCTOU D1](AUDIT.md)). Le minimum viable : afficher l'âge du scan dans la barre d'état, et re-vérifier l'existence/type de la cible juste avant toute action destructive.

### J5.3 · 🔵 · Splash figé (renvoi C4) — vécu quotidien

Brancher le disque externe *après* l'ouverture de l'app : sa carte n'apparaît jamais (il faut relancer ou re-naviguer Home). Débrancher un volume dont le résultat est affiché : toutes les actions échouent en silence (croisement J4.6). `NSWorkspace.didMount/didUnmount` réglerait les deux à peu de frais.

---

## 6. Parcours J6 — Scanner une VM (Podman / Colima)

### J6.1 · 🟠 · Le scan « Containers storage » n'est pas exposé dans l'UI

Prouvé par grep : `VMScope.containers` n'est instancié que par le mode headless ; le splash ne crée que `VMCard(scope: .full)` ([ContentView.swift:370](Sources/MacDirStats/Views/ContentView.swift#L370)) et `AppModel` n'a que `scanVMFilesystem` (`.full`). La fonctionnalité — cibler `GraphRoot`, le sous-arbre le plus utile pour un dev qui cherche pourquoi sa VM podman fait 60 Go — est **codée, testée en headless (`--vm-scan podman containers`), et invisible**. Une deuxième carte par VM (« Container storage ») suffit.

### J6.2 · 🔵 · VM stoppée : bien signalée, mais sans action

La carte grisée « Stopped » ([VMCard](Sources/MacDirStats/Views/ContentView.swift#L506-L569)) est honnête ✅, mais l'étape suivante évidente — `podman machine start` / `colima start` — est à faire au terminal. Un bouton « Démarrer » (avec spinner, via le ProcessRunner de [C1](AUDIT.md)) fermerait la boucle.

### J6.3 · 🟠 · Échec du find distant : un scan vide « réussi » (renvoi C2, vécu concret)

Si `sudo`, `stdbuf` ou `find -printf` manquent dans la VM (images busybox/Alpine), le stderr part dans `nullDevice`, l'exit code n'est pas lu : l'utilisateur obtient un résultat **0 octet, 0 erreur, état "terminé"**. Au quotidien : « le scan VM ne marche pas » sans aucun indice. Un pré-vol de 200 ms (`ssh … 'command -v find && find --version'`) discriminerait GNU/busybox et afficherait un message actionnable.

### J6.4 · ⚪ · Ce qui est bien conçu (à créditer et documenter)

`find -xdev` exclut les montages virtiofs/sshfs de pass-through du home hôte (`/Users` monté dans la VM) — sans quoi le scan VM re-compterait tout le disque du Mac : choix **juste et non documenté**. Les bind-mounts CoreOS (`/var` même device) restent couverts. Limite résiduelle acceptée : un éventuel second disque de données attaché à la VM est silencieusement exclu.

### J6.5 · 🔵 · Lecture seule non expliquée

En scan VM, le menu contextuel se réduit à « Copy Path (in VM) » — correct, mais rien n'explique *pourquoi* pas de suppression ici. Une ligne d'aide (« lecture seule : le filesystem appartient à la VM ») éviterait la perception de bug.

---

## 7. Parcours J7 — Mode Containers

- **J7.1 · 🟠 — Utilisateur Docker Desktop : rien.** `ContainerProbe.detect` ne sonde que podman ([ContainerEngine.swift:62-69](Sources/MacDirStats/Scanner/ContainerEngine.swift#L62-L69)) ; pas de carte, pas de message « Docker détecté mais non supporté ». L'enum `Kind.docker` promet le contraire ([H1](AUDIT.md)).
- **J7.2 · 🔵 — Incohérence d'affordance** : une VM podman stoppée apparaît (grisée) dans la section VM, mais la section Containers, elle, **disparaît entièrement** si la machine ne tourne pas — même produit, deux comportements pour le même état.
- **J7.3 · 🟡 — `rmi -f` sous-documenté** : l'alerte dit « will be deleted » sans préciser que les **conteneurs dépendants seront supprimés aussi** (comportement de `-f`). Pour un dev, perdre un conteneur configuré est la vraie casse.
- **J7.4 · 🔵 — Rupture de langage visuel** : seul mode sans aucune visualisation surfacique (ni treemap ni barres proportionnelles de section) ; les images en ont, conteneurs/volumes non. Un mini-treemap images/volumes réutiliserait `TreemapLayout.squarify` tel quel (le mode K8s l'a déjà fait).
- **J7.5 · 🔵 — Prune sans inventaire** (renvoi D3) : « Remove all unused volumes? » sans lister lesquels, alors que `volumes.filter { !$0.inUse }` est déjà en mémoire — 5 lignes pour un consentement éclairé.

---

## 8. Parcours J8 — Mode Kubernetes

- **J8.1 · 🟠 — Le kubeconfig réel est plein de cadavres** : tous les contexts sont listés en cartes équivalentes ; cliquer un cluster décommissionné = spinner infini ([C1](AUDIT.md)/[C3](AUDIT.md)). Au quotidien c'est LE piège du mode. Mitigations : ping asynchrone (`kubectl version --request-timeout=2s`) qui grise les morts, badge de latence, timeout visible.
- **J8.2 · 🔵 — Pas de filtre** : sur un cluster à 40 namespaces, ni recherche, ni tri alternatif, ni repli de tout/rien. La barre ⌘F du mode filesystem n'a pas d'équivalent ici.
- **J8.3 · 🔵 — « Il manque mes clusters »** : app lancée du Finder → `KUBECONFIG` multi-fichiers non hérité (renvoi C5) — divergence terminal/GUI inexpliquée pour l'utilisateur.
- **J8.4 · 🟡 — Jauges vides pendant 30–60 s** sur clusters larges (usage séquentiel par nœud, [E4](AUDIT.md)) : l'utilisateur croit la feature cassée avant que ça n'arrive. Barre « usage 3/50 nodes » présente ✅ mais discrète.

**Positifs J8** : chargement progressif exemplaire ; désactivation propre du sélecteur Used tant qu'indisponible ; badges RWO/RWX et phases ; copie PV/PVC pensée pour l'action CLI derrière.

---

## 9. Parcours J9 — « Pourquoi ça ne matche pas ? » (réconciliation des chiffres)

Le sujet n° 1 des reviews d'outils de ce type. Quatre écarts coexistent, aucun n'est adressé :

| Écart | Cause | État |
|---|---|---|
| Scan ≠ « used » de la carte volume | Snapshots APFS locaux (Time Machine), purgeable, métadonnées FS — invisibles à un scan fichiers | Aucune mention |
| Carte « free » ≠ Finder | `volumeAvailableCapacity` strict vs Finder qui inclut le purgeable (`…ForImportantUsage`) | Aucune mention |
| Tailles ≠ Finder fichier par fichier | Base 1024 étiquetée « KB/MB » vs Finder base 10 ([A10](AUDIT.md)) | Assumé en commentaire code |
| Scan > attendu | Montages traversés ([A1](AUDIT.md)), hardlinks par lien ([A3](AUDIT.md)) | Documenté README seulement |

**Proposition à fort impact** : un panneau « Réconciliation » en fin de scan de volume — `Total volume utilisé (API) = scan + corbeille + snapshots (tmutil listlocalsnapshots) + purgeable + non lisible (skipped) + delta` — transforme la première objection de tout utilisateur en démonstration de sérieux. Les données sont toutes accessibles (API capacités, `errorCount`, taille de `.Trash`).

À noter aussi (J9.5 · ⚪) : la locale est **mixte** — `Format.count` passe par `NumberFormatter` (localisé : « 1 234 567 » en fr) mais `Format.bytes` par `String(format:)` non localisé (« 1.5 GB », point décimal) : un utilisateur français voit les deux conventions dans la même barre d'état.

---

## 10. Parcours J10 — Accessibilité, ergonomie système

- **J10.1 · 🟠 — VoiceOver : app inutilisable.** Grep : zéro modificateur `accessibility*`. Le treemap est un `Canvas` (invisible pour AX), les lignes sont des `HStack+onTapGesture` sans label ni actions, les jauges K8s sont des dessins muets. Même sans viser une conformité complète, `accessibilityLabel` sur les lignes (nom + taille + profondeur) et `accessibilityChildren` basiques sur le treemap sont atteignables.
- **J10.2 · 🔵 — Daltonisme** : l'information « type de fichier » n'est portée que par la teinte (16 teintes, collisions fréquentes) ; les jauges vert/orange/rouge n'ont ni forme ni texte de secours. Le pourcentage en tooltip/label ferait le fallback.
- **J10.3 · 🔵 — Typographies figées 9–13 pt** : pas de réaction à la préférence de taille de texte ; sur écran 4K en « More Space », c'est petit. Un modificateur d'échelle global dans `Theme` suffirait.
- **J10.4 · ⚪ — i18n** : tout est hardcodé anglais (cohérent avec la cible actuelle) ; le jour venu, le mélange de locales de J9.5 est le premier chantier.

---

## 11. Énergie & ressources au quotidien

- **J11.1 · 🟡 — App Nap** (cf. J2.3) : le seul vrai problème énergie/latence, 4 lignes de fix.
- **J11.2 · ⚪ — Timer 10 Hz sans `tolerance`** ([ScanController.swift:597-603](Sources/MacDirStats/ViewModel/ScanController.swift#L597-L603)) : empêche le coalescing des réveils. `timer.tolerance = 0.02` est gratuit. Le timer s'arrête bien hors scan ✅ — l'app idle est réellement à ~0 % CPU (bonne hygiène, à préserver).
- **J11.3 · ⚪ — Batterie** : 12 threads plein régime, aucun égard pour `isLowPowerModeEnabled`. Un scan de disque est court ; un scan VM streamé peut durer. Basculer les workers en `.utility` sur batterie faible = compromis raisonnable.
- **J11.4 · ⚪ — RAM du scan VM** : `nodes: [String: FSNode]` garde un chemin **complet** par répertoire de la VM pendant tout le scan (~100 Mo transitoires par million de dossiers) — en tension avec la promesse « low-RAM » du README. `find` émet en DFS : une pile de `(chemin, nœud)` remplacerait le dictionnaire pour l'essentiel des lookups.

---

## 12. Inventaire des fonctionnalités mortes ou introuvables (prouvé par grep)

| Élément | État | Impact quotidien |
|---|---|---|
| `zoomOut()` / `resetZoom()` | Jamais appelés | Cul-de-sac de zoom (J3.5) + README mensonger |
| `VMScope.containers` | Jamais exposé en GUI | La cible VM la plus utile absente (J6.1) |
| `scan(volumes:)` multi | Toujours appelé avec 1 seul volume | La racine virtuelle « N disks » et l'agrégat multi-disques sont du code mort côté UI ; pas de carte « Analyser tous les disques » |
| « Ouvrir un dossier » | Menu ⌘O uniquement | Action top-3 invisible sur le splash : ni carte « Choisir un dossier… », ni drag & drop (grep : zéro `onDrop`/`draggable`), ni « Ouvrir avec » Finder |
| `ContainerEngine.Kind.docker` | Jamais détecté | Promesse d'enum non tenue (J7.1) |
| `CImage.dangling`, `CImage.created`, `Theme.stableUnit` | Calculés, jamais lus | Badge « dangling » et tri par âge à portée de main ; 2e niveau de couleur inutilisé |

Ce tableau raconte une seule histoire : **le delta entre ce que le moteur sait faire et ce que l'UI expose est la réserve de valeur la moins chère du projet.**

---

## 13. Matrice de synthèse (gravité quotidienne = fréquence × douleur)

| ID | Grav. | Parcours | Résumé | Effort |
|---|---|---|---|---|
| J3.5 | 🔴 | Explorer | Aucun dézoom treemap dans l'UI (+ README drift) | XS |
| J4.1 | 🔴 | Nettoyer | Suppressions synchrones → beachball | S |
| J4.4 | 🟠 | Nettoyer | Delete pendant scan permis → totaux corrompus | XS (gate) |
| J4.6 | 🟠 | Nettoyer | Échec de suppression sans aucun feedback | XS |
| J4.2 | 🟠 | Nettoyer | Pas de ⌘⌫ ni multi-sélection | M (List native) |
| J3.1 | 🟠 | Explorer | Zéro navigation clavier | M (idem) |
| J3.2 | 🟠 | Explorer | Pas de QuickLook | S |
| J1.3 | 🟠 | Installer | Onboarding FDA incomplet (boucle Relaunch) | S |
| J2.2 | 🟠 | Scanner | « skipped » inactionnable | S |
| J6.1 | 🟠 | VM | Scope containers non exposé | XS |
| J7.1 | 🟠 | Containers | Docker non détecté sans message | S–M |
| J8.1 | 🟠 | K8s | Contexts morts → spinner infini | S (avec C1) |
| J10.1 | 🟠 | A11y | VoiceOver inutilisable | M |
| J2.1 | 🟠 | Scanner | Cascade de prompts TCC en plein scan | S |
| J9.* | 🟠 | Confiance | Aucune réconciliation des chiffres | M |
| J2.3/J11.1 | 🟡 | Scanner | App Nap non gérée | XS |
| J2.5 | 🟡 | Scanner | Cibles mouvantes → misclicks | S |
| J3.3 | 🟡 | Explorer | Hover sans chemin | XS |
| J3.4 | 🟡 | Explorer | Pas de menu contextuel treemap | S |
| J3.6 | 🟡 | Explorer | Troncature 2 000 fichiers silencieuse | XS |
| J4.3 | 🟡 | Nettoyer | Corbeille ≠ espace libéré, pas de compteur session | S |
| J5.1 | 🟡 | Rescan | Perte de contexte au rescan | S |
| J5.2 | 🟡 | Sessions | Pas d'âge du scan / staleness | XS |
| J2.4 | 🟡 | Scanner | Quit sans confirmation en plein scan | XS |
| J6.3 | 🟠 | VM | Scan VM vide « réussi » sans diagnostic | S |
| J7.3 | 🟡 | Containers | `rmi -f` : dépendances non annoncées | XS |
| J8.4 | 🟡 | K8s | Jauges vides 30–60 s (séquentiel) | S |
| J1.1 | 🟡 | Installer | Pas de distribution binaire | M |
| J1.2 | 🔵 | Installer | Icône générique | XS |
| J1.4 | 🔵 | Installer | Usage descriptions TCC absentes | XS |
| J3.7–J3.10 | 🔵 | Explorer | Tri unique, recherche sans sortie, fenêtre anonyme, splitters | S |
| J5.3 | 🔵 | Sessions | Splash figé (mount/unmount) | XS |
| J6.2/J6.5 | 🔵 | VM | Pas de démarrage VM ; lecture seule inexpliquée | S |
| J7.2/J7.4/J7.5 | 🔵 | Containers | Affordances incohérentes, pas de visu, prune aveugle | S |
| J8.2/J8.3 | 🔵 | K8s | Pas de filtre ; KUBECONFIG | S |
| J10.2/J10.3 | 🔵 | A11y | Daltonisme, tailles figées | S |
| J11.2–J11.4 | ⚪ | Ressources | Tolerance timer, batterie, RAM scan VM | XS–S |
| J9.5 | ⚪ | i18n | Locale mixte nombres/octets | XS |
| §12 | — | Produit | 6 features mortes/cachées inventoriées | XS–S chacune |

---

## 14. Backlog suggéré : « le premier mois d'un utilisateur heureux »

**Semaine 1 — Débloquer les culs-de-sac (tout est XS/S) :**
dézoom (⌘↑, Échap, double-clic fond, bouton) + fix README · gate des suppressions pendant scan · feedback d'échec de suppression · suppressions asynchrones avec état « en cours » · App Nap (`beginActivity`) · ligne « … et N autres » · hover avec chemin · icône d'app.

**Semaine 2 — Le flux nettoyage digne du produit :**
menu contextuel sur le treemap · compteur de session « déplacé en corbeille : X GB » + bouton Vider · confirmation enrichie (n fichiers, taille, date) · quit-guard pendant scan/suppression · titre de fenêtre + persistance des splitters.

**Semaine 3 — Clavier & confiance :**
migration `List(selection:)` native → flèches, ⌘⌫, multi-sélection, menus standard · QuickLook (espace) · panneau de réconciliation des chiffres · « skipped » cliquable avec CTA FDA · onboarding FDA corrigé.

**Semaine 4 — Ouvrir les modes :**
carte « Container storage » par VM · pré-vol + erreurs visibles du scan VM · détection Docker (ou message honnête) · ping des contexts K8s + timeouts · carte « Choisir un dossier… » + drag & drop sur fenêtre/Dock · carte « Tous les disques » (le moteur multi-seed existe).

---

*Ce rapport complète [AUDIT.md](AUDIT.md) (exactitude, concurrence, résilience, algorithmique). Les renvois [A*/B*/C*/D*/E*/F*/H*/S*] pointent vers les findings de fond qui sous-tendent plusieurs symptômes quotidiens décrits ici. Tous les « absent/jamais appelé » de ce document ont été vérifiés par grep sur l'arbre source au 2026-07-02.*
