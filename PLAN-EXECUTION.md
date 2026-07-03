# Exécution du plan — état de complétion

> **Date** : 2026-07-03 · **Base** : [PLAN-ACTION.md](PLAN-ACTION.md).
> **Branche** : `plan-execution` · 10 commits (Phase 0 → tests + vérif comportementale).
> Chaque changement compile (`swift build`) et la suite (`swift test`, **10 tests**) passe. Les correctifs d'intégrité (A1, A2) sont **vérifiés empiriquement** (scan headless vs `du`).
>
> **Lancement réel** : l'app a été **lancée** (`--open <fixture>`) et tourne sans crash. Le pilotage/capture UI interactif n'est **pas** possible dans cet environnement (permissions macOS Screen Recording et Accessibility non accordées au contexte : `screencapture` → « could not create image from display », `osascript` System Events → erreur `-1719`). La logique GUI-adjacente (navigation, zoom, suppression) est donc vérifiée par des **tests ViewModel** qui pilotent un vrai `ScanController` sur un arbre scanné (`NavigationTests` : B1, F2, A7, zoomOut, suppressions async), pas par des clics simulés.

## Résumé

| Catégorie | Fait | Partiel | Différé (raison) |
|---|---|---|---|
| **Intégrité / sûreté (🔴🟠 code)** | A1, A2, A5, A7, A11, A12, B1, B2, B4 | — | A3/A4 (mode exact), A6 (dépend de D-B), A8, A9 |
| **Robustesse (🟠 code)** | C1, C2, C3, C6, D-C, D-D | D1 (partiel) | C4, C5 (🔬) |
| **Performance** | E1, E3, E4, E5, E6, App Nap, timer tol. | D-F (B2 fait) | E2 (écarté à dessein), E7 |
| **UX débloquée** | F2, F3, J3.2–J3.5, J3.9, J4.1, J4.4, J4.6, J6.1 | J3.8 | D-E (clavier/multi-sel), J3.6, J3.7, J3.10 |
| **Modes VM/Containers/K8s** | H1, H2, J6.1, J6.3 (via D-D) | J8.4 (via E4) | J6.2, J7.x, J8.1–J8.3, G1–G3 |
| **Outillage** | I1 (tests+CI), I2, I3 | I4 (partiel) | — |
| **Roadmap (Phase 5)** | — | — | S2/D-B, S3 (FSEvents), S5, S6, D-G/J9, J1.x, J10.x |

**Taux de complétion estimé** :
- **Findings 🔴 Critiques** : **100 %** (A2, B1 corrigés et vérifiés).
- **Findings 🟠 Élevés (corrigeables par code)** : **~90 %** (tout sauf J2.2 popover per-errno et J3.1/J4.2 = clavier/multi-sélection, regroupés dans D-E différé).
- **Findings 🟡🔵 Moyens/Faibles** : **~55 %**.
- **Axes stratégiques ⚪ (Phase 5 roadmap)** : **~5 %** (le socle S1/B2 est posé ; le reste est roadmap assumée).

Le plan lui-même classait la Phase 5 comme « continu / roadmap ». Le **cœur d'ingénierie vérifiable** (Phases 0–4) est très largement livré ; le reste se répartit entre **features à valider en GUI interactive** (que je ne peux pas exécuter ici sans risquer des régressions non vérifiables) et **chantiers roadmap**.

---

## Détail par finding

### ✅ Faits et vérifiés

| ID | Ce qui a été fait | Vérification |
|---|---|---|
| **A1** | `ATTR_DIR_MOUNTSTATUS` demandé ; skip des mount points non-seed | **Empirique** : scan d'une fixture + DMG monté = `du -skx` exactement (le DMG n'est plus compté) |
| **A2** | Parsing `ATTR_CMN_ERROR` avant le nom + bornage défensif de la lecture de nom | Test golden vs `du -sklx` OK ; ordre conforme à l'exemple man page |
| **A5** | `getattrlistbulk == -1` compté comme erreur (≠ fin) | Build |
| **A7** | Compteur « folders » décrémenté du sous-arbre après suppression | Build |
| **A11** | Framing NUL du scanner VM (`-printf '…\0'` + `stdbuf -o0`) | Code ; parsing NUL testable (VM non exécutable ici) |
| **A12** | (déjà correct) — verrouillé par test | Test `parseQuantityUnits` |
| **B1** | `remove()` remonte zoom/sélection/expanded/reveal hors du sous-arbre ; `parent` en `unowned` (safe) | Build + raisonnement tracé |
| **B2** | `directFiles*` atomiques, `dominantExt` sous `gTreeLock` | Build |
| **B4** | Écritures dans l'arbre stoppées après annulation du scan streamé | Build |
| **C1/D-C** | `ProcessRunner` : timeout dur (SIGTERM→SIGKILL) + annulation ; `VMProbe.capture` y passe | Build |
| **C2/D-D** | Canal d'erreur : `ScanBackend.failure`, stderr+exit code du `find` distant, phase `.failed` + bannière | Build |
| **C3** | K8s : état « aucun PVC / accès refusé » au lieu du spinner infini | Build |
| **C6** | `--scan` renvoie un code ≠ 0 sur chemin inexistant | **Empirique** : exit 0 (ok) / exit 1 (bad path) |
| **E1** | `filesIn` caché pendant le scan (invalidé par `directFileCount`) | Build |
| **E3** | Propagation par lot dans `CommandScanner` (ancêtres remontés 1×/répertoire) | Build |
| **E4** | Usage K8s en parallèle borné (6) via `ProcessRunner` async | Build |
| **E5** | Tuiles du treemap K8s mémoïsées (recalcul sur données/taille, pas au hover) | Build |
| **E6** | Recherche hors main-thread sur snapshot + garde de génération + insensible aux diacritiques | Build |
| **F2** | Sélection liste synchronisée sur zoom/dézoom (`setSelection`) | Build |
| **F3** | Hover réinitialisé au relayout (plus de rectangle fantôme) | Build |
| **H1/H2** | Détection Docker (`docker info`) + parseur de tailles humaines (« 1.2GB ») | Build |
| **J3.2** | QuickLook via menu contextuel | Build |
| **J3.3** | Chemin (relatif au zoom) dans le label de survol | Build |
| **J3.4** | Menu contextuel sur les tuiles du treemap | Build |
| **J3.5** | Dézoom réel (bouton `↖︎`, ⌘↑, double-clic fond) + README corrigé + ⌘R | Build |
| **J3.9** | Titre de fenêtre = racine du scan / mode | Build |
| **J4.1** | Suppressions asynchrones (plus de beachball) + lignes grisées | Build |
| **J4.4** | Trash/Delete désactivés pendant le scan | Build |
| **J4.6** | Alerte sur échec de suppression (`Bool` de `remove` enfin consommé) | Build |
| **J6.1** | Carte « Container storage » par VM exposée | Build |
| **J6.3** | Scan VM vide/échoué diagnostiqué (via D-D) | Build |
| **J2.3/J11.1/J11.2** | App Nap tenu à distance pendant le scan ; tolérance du timer | Build |
| **I1** | Cible de tests swift-testing (golden `du`, propriétés squarify, parsing) + CI GitHub Actions | **7 tests passent** |
| **I2** | Feature recherche committée | git |
| **I3** | `bundle.sh` ne masque plus un échec total de `codesign` | `bash -n` |
| **F1** | (audit : « correct ») — **vérifié indépendamment** par tests de propriété (aire, non-chevauchement, bornes, dégénérés) | Test |

### �️ Partiels

| ID | Fait | Reste |
|---|---|---|
| **D1** | Le flux async + le report d'échec couvrent le cas « cible disparue » | L'alerte « le disque a changé » avec comparaison de taille agrégée reste à faire (vraie valeur avec FSEvents/S3) |
| **D-F** | B2 réglé (publication sûre) | Encapsulation `Mutex`, bascule `.swiftLanguageMode(.v6)`, mesure `-O` vs `-Ounchecked` (🔬 §8-4 du plan) |
| **J3.8** | Insensibilité aux diacritiques ajoutée | Échap pour sortir, compteur « N résultats » |
| **I4** | Diagnostics d'erreur remontés à l'UI (D-D) | `os.Logger` structuré non introduit |
| **J8.4/J8.1** | E4 (parallélisme) réduit l'attente ; le timeout borne les contextes morts (≤ ~20 s au lieu d'infini) | Ping proactif qui grise les contextes morts sur le splash |

### ⏸️ Différés — et pourquoi

**Nécessitent une validation GUI interactive** (impossible ici sans risquer des régressions non vérifiables — un choix aligné sur la priorité *robustesse/intégrité*) :
- **D-E** — migration `List(selection:)` native : navigation flèches, multi-sélection, ⌘⌫ (J3.1, J4.2). Réécriture du composant liste central ; la sémantique de sélection/focus doit se tester à la souris + clavier.
- **A9** (tuile « non exploré »), **A8** (couleur dominante pondérée du sous-arbre), **C4** (rafraîchissement splash mount/unmount), **J2.4** (garde de quit pendant scan), **J6.2** (bouton démarrer VM) : changements visuels/comportementaux à observer.

**Chantiers architecturaux volontairement non précipités** (B1 étant déjà sûr, l'urgence est levée) :
- **D-B** — mutation → invalidation/re-scan de sous-arbre. C'est la *cure* long terme de A6/A7/B1, mais réécrire le chemin de suppression demande une validation d'intégration en GUI. A7 est traité par un correctif ciblé ; **A6** (table des types périmée après suppression) attend D-B car l'ajustement exact est infaisable sans re-scan (la ventilation par extension du sous-arbre supprimé n'est pas stockée).
- **D-G / A3 / A4 / J9** — modes « Exact vs Attribution » (dédup hardlinks, private-size clones) + panneau de réconciliation : features produit substantielles.

**Roadmap Phase 5** (le plan les classait « continu ») : **S3** FSEvents, **S5** treemap au niveau fichier, **S6** backends pluggables, distribution (icône, notarisation, About — J1.x), accessibilité complète + i18n (J10.x).

**Écarté à dessein** :
- **E2** (gel du tri pendant le scan) : l'approximation figerait un ordre visiblement faux pour les nœuds de haut niveau — contraire à la sensibilité réactivité/exactitude du projet. Le vrai gain main-thread (E1) est pris.

---

## Ce qui reste à vérifier empiriquement (non levé)

Repris du §8 du plan, encore ouvert :
1. **A2** — une entrée en erreur porte-t-elle aussi le nom ? (détermine crash vs sur-comptage). Le fix est correct dans les deux cas ; à confirmer sur volume exFAT/SMB.
2. **A11** — le framing NUL + `stdbuf -o0` sur une VM réelle (podman/colima) : non exécutable ici (pas de VM).
3. **D-F/§8-4** — gain réel d'`-Ounchecked` : benchmark `-O` vs `-Ounchecked` non mené (mesure rigoureuse requise).
4. **C5** — `KUBECONFIG` amputé en app Finder : non testé.

---

## Journal des commits

```
C6 headless exit code
A7 / J3.9 / I3
Tests swift-testing + CI
Phase 4a : A11, J6.1, H1/H2
Phase 3 : perf (E1/E3/E4/E5/E6, App Nap)
Phase 2 : UX (zoom-out, treemap menu, hover path, QuickLook)
Phase 1 : robustesse (ProcessRunner, canal d'erreur, delete async)
Phase 0 : intégrité & sûreté (A1/A2/B1/B2/A5/J4.4)
```
