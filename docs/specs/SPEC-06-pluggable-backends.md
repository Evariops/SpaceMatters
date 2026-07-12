# SPEC-06 — Pluggable scan backends

> **Findings**: S6. H1 (Docker) is **already done**. Extends the `ScanBackend` contract.
> **Status**: ✅ **IMPLEMENTED** — enriched contract + generic SSH backend + splash card.

## 0. Implementation result

- **Enriched contract** ([ScanBackend.swift](../../Sources/SpaceMatters/Scanner/ScanBackend.swift)): `var source: ScanSource { get }` (`host | vm | remote | archive`, with `isReadOnly`/`label`) + `func diagnostics() -> String`, defaults provided. The UI already gates destructive actions on `!isHostScan` (⇒ remote/vm read-only).
- **Shared `find` command**: `RemoteFind.command(rootPath:sudo:)` + centralized `printf` — VMProbe **and** SSH reuse it (no more format drift).
- **Generic SSH backend**: `SSHTarget` (user/host/port/path/identity/sudo) → `command()` builds `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new … <find>`. `ScanController.scanRemote` / `AppModel.scanRemote` launch a `CommandScanner` (`source: .remote`) — **reuses 100% of the existing streamed-flow parser**, nearly free.
- **Splash UI**: "Remote" section → `RemoteCard` → `RemoteScanSheet` (host/user/path/port/identity/sudo form, read-only note + key-based auth).
- **Tests**: `sshTargetBuildsFindCommand`, `hostOnlyTargetOmitsUserAndOptionals`, and **`commandScannerParsesFindStream`** (the SSH parser exercised locally via `printf` in the exact NUL format — tree/sizes/dirCount/extensions validated).
- **🔬 Not testable here**: a real SSH scan requires Remote Login **and** GNU `find`/`-printf` on the remote side (macOS's `find` doesn't have it) — exactly the case the D-D error channel diagnoses (J6.3).

## 1. Objective

Make `ScanBackend` a true extension point for adding scan sources (generic SSH, archives, Time Machine, another Mac) with minimal effort per backend, building on the existing infrastructure (live tree, error channel, `ProcessRunner`).

## 2. Current state (verified)

- `ScanBackend` ([ScanBackend.swift](../../Sources/SpaceMatters/Scanner/ScanBackend.swift)): `start/cancel/isFinished/directoryCount/scanErrorCount/failure/snapshotExtensions`. **`failure` already added** (D-D error channel).
- Two implementations: `DirectoryScanner` (local syscalls) and `CommandScanner` (streamed SSH `find`, NUL framing already fixed). The `CommandScanner` is already **90% of a generic SSH backend**.
- `ProcessRunner` (timeout + cancellation) available.

## 3. Axes & tradeoffs

- Enrich the contract with: `var source: ScanSource { get }` (`host | vm(machine) | remote(host) | archive(url)`), `func diagnostics() -> String`. Lets the UI adapt actions (read-only for remote/archive, cf. J6.5).
- New backends, in order of ease:
  - **Generic SSH**: `CommandScanner` with a `ssh user@host 'find … -printf …\0'` command — nearly free.
  - **Time Machine**: `tmutil` + traversal of a mounted snapshot.
  - **Archives** (`tar`/`zip`): list the entries + sizes → feed the tree (no deletion).
  - **Another Mac**: generic SSH + auth.

## 4. Implementation plan

1. Add `source`/`diagnostics` to the protocol (defaults provided).
2. Generalize `CommandScanner`: accept an arbitrary command (exe+args) + a `rootPath` — already almost the case; extract a `RemoteFindConfig`.
3. `SSHScanBackend`: builds the remote `find` command (reuses a generalized `VMProbe.scanCommand`); key/host handling.
4. Splash UI: "Remote server…" card (host + path); actions gated on `source.isReadOnly`.

## 5. Verification

- **Test**: parsing of the remote `find` stream (already covered by the `CommandScanner` tests).
- **Live**: SSH to `localhost` on a folder → populated tree, read-only (no trash).

## 6. Risks & assumptions

- 🔬 Availability of GNU `find`/`-printf` on the remote side (busybox) — already diagnosed by the error channel (J6.3).
- SSH auth (key/agent) out of scope for v1: document the prerequisites.

## 7. Effort & dependencies

**~1 day per backend.** The enriched contract: ~½ day. Independent.
