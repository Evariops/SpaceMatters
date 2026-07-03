# SPEC-06 — Backends de scan pluggables

> **Findings** : S6. H1 (Docker) est **déjà fait**. Étend le contrat `ScanBackend`.

## 1. Objectif

Faire de `ScanBackend` un vrai point d'extension pour ajouter des sources de scan (SSH générique, archives, Time Machine, autre Mac) avec un minimum d'effort par backend, en s'appuyant sur l'infrastructure existante (arbre live, canal d'erreur, `ProcessRunner`).

## 2. État actuel (vérifié)

- `ScanBackend` ([ScanBackend.swift](../Sources/MacDirStats/Scanner/ScanBackend.swift)) : `start/cancel/isFinished/directoryCount/scanErrorCount/failure/snapshotExtensions`. **`failure` déjà ajouté** (canal d'erreur D-D).
- Deux implémentations : `DirectoryScanner` (syscalls locaux) et `CommandScanner` (`find` streamé SSH, framing NUL déjà corrigé). Le `CommandScanner` est déjà **90 % d'un backend SSH générique**.
- `ProcessRunner` (timeout + annulation) disponible.

## 3. Axes & tradeoffs

- Enrichir le contrat de : `var source: ScanSource { get }` (`host | vm(machine) | remote(host) | archive(url)`), `func diagnostics() -> String`. Permet à l'UI d'adapter les actions (lecture seule pour remote/archive, cf. J6.5).
- Nouveaux backends, par ordre de facilité :
  - **SSH générique** : `CommandScanner` avec une commande `ssh user@host 'find … -printf …\0'` — quasi gratuit.
  - **Time Machine** : `tmutil` + parcours d'un snapshot monté.
  - **Archives** (`tar`/`zip`) : lister les entrées + tailles → alimenter l'arbre (pas de suppression).
  - **Autre Mac** : SSH générique + auth.

## 4. Plan d'implémentation

1. Ajouter `source`/`diagnostics` au protocole (défaut fournis).
2. Généraliser `CommandScanner` : accepter une commande arbitraire (exe+args) + un `rootPath` — déjà presque le cas ; extraire un `RemoteFindConfig`.
3. `SSHScanBackend` : construit la commande `find` distante (réutilise `VMProbe.scanCommand` généralisé) ; gestion clé/hôte.
4. UI splash : carte « Serveur distant… » (host + chemin) ; actions gatées `source.isReadOnly`.

## 5. Vérification

- **Test** : parsing du flux `find` distant (déjà couvert par les tests `CommandScanner`).
- **Live** : SSH vers `localhost` sur un dossier → arbre peuplé, lecture seule (pas de corbeille).

## 6. Risques & hypothèses

- 🔬 Disponibilité de GNU `find`/`-printf` côté distant (busybox) — déjà diagnostiqué par le canal d'erreur (J6.3).
- Auth SSH (clé/agent) hors périmètre v1 : documenter les prérequis.

## 7. Effort & dépendances

**~1 jour par backend.** Le contrat enrichi : ~½ jour. Indépendant.
