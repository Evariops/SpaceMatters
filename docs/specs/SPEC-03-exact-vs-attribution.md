# SPEC-03 — Exact counting vs attribution + reconciliation of the figures

> **Findings**: A3 (hardlinks counted per link), A4 (APFS clones not deducted), A10 (base 1024 labeled KB), J9 ("why doesn't it match Finder?"), J9.5 (mixed locale). Refers to D-G/S4 of the plan. A1 (mounts) is **already fixed**.
> **Status**: ✅ **IMPLEMENTED** — A3 exact (validated against `du`), A10/J9.5, J9 reconciliation. A4 in honest fallback (conforms to §3.b/§6).

## 0. Implementation result

- **A3 hardlinks (exact) — validated against `du`**: `CountingMode { attribution | exact }` (toolbar toggle, host). In exact mode, the bulk enumerator requests `ATTR_CMN_FILEID` + `ATTR_FILE_LINKCOUNT` (read in exact bit order; **the default attribution mode packs an identical buffer** — reads guarded by the `returned` mask), and the scanner dedups multi-link inodes (`Set<UInt64>`, only `linkCount > 1` → negligible memory). Golden test `exactModeDedupsHardlinks`: exact ↔ `du -skx`, attribution ↔ `du -sklx`. Switching = re-scan (dedup at scan time). VM = attribution.
- **A10 + J9.5 (format)**: `Format.bytes` → base 1024 with **honest IEC labels** (KiB/MiB/…), **localized** decimal separator. Test `formatBytes` updated.
- **J9 reconciliation**: `Reconciliation` (model) + `ReconciliationButton`/popover (whole-volume scans). Breaks down "used (API)" = scan + trash (`~/.Trash` + `.Trashes`) + purgeable (`importantUsage − available`, with snapshot count via `tmutil`) + unattributed; flags `scanExceedsUsed` (signature of attribution over hardlinks/clones) and the unreadable paths. Test `reconciliationArithmetic`.
- **A4 APFS clones — honest fallback (conforms to the plan)**: §3.b/§6 flagged `ATTR_CMNEXT_PRIVATESIZE` 🔬 "to prototype / honest fallback if unreliable". Parsing extended attributes (`forkattr`) is riskier than the standard buffer; **not adopted**. Instead, an explicit UI note (toggle tooltip + reconciliation panel): "APFS clones are counted full in both modes and may inflate the total beyond `df`".
- **A1 (mounts)**: already fixed.

## 1. Objective

Formalize two explicit **counting modes** and settle the first objection of any user ("it doesn't match Finder/df"):
- **Attribution** (current default): "who is responsible for the space" — hardlinks per link, clones full.
- **Exact disk**: dedup hardlinks + private size of clones + bounded to the volume (A1 already done) → **matches `df`**.
Plus a **reconciliation panel** that breaks down the gap with the volume's "used" space.

## 2. Current state of the code (verified)

- `physical` = Σ `fileAllocSize` ([FSAttr.swift](../../Sources/SpaceMatters/Scanner/FSAttr.swift), `ATTR_FILE_ALLOCSIZE`). Hardlinks: each link counted (validated = `du -skl`). Clones: counted full.
- A1 (mount status): **fixed and verified** — the scan stays on the volume (`du -skx`).
- `Format.bytes` ([Formatting.swift:5](../../Sources/SpaceMatters/Util/Formatting.swift#L5)): base 1024, "KB/MB" labels (not localized); `Format.count` localized (J9.5, mixed locale).
- The volume already exposes capacities via `Volume` / `URLResourceValues`.

## 3. Design axes & tradeoffs

### 3.a Hardlinks (A3)
- Request `ATTR_CMN_FILEID` + `ATTR_CMN_DEVID` + `ATTR_FILE_LINKCOUNT` in the bulk.
- For `nlink > 1` entries only: dedup via `Set<UInt64>` keyed `(dev, ino)` (or `[dev: Set<ino>]`). Count blocks only at the **first** occurrence. Memory bounded to the number of multi-link files (marginal).
- *Tradeoff*: +12 bytes/entry in the bulk buffer, a shared `Set` under lock (or per-worker merged). In "Exact" mode only.

### 3.b APFS clones (A4)
- `ATTR_CMNEXT_PRIVATESIZE` (unshared size per file) via `FSOPT_ATTR_CMN_EXTENDED` + `forkattr`. 🔬 availability/reliability varies across versions, larger buffer cost — **to be measured before adopting**.
- Honest fallback if unreliable: UI note "APFS clones may inflate this total".

### 3.c Reconciliation (J9)
Panel at the end of a volume scan:
```
Volume used (API)  = scan + trash + local snapshots + purgeable + unreadable + delta
```
- scan = measured total; trash = size of `~/.Trash` (and the volume's `.Trashes`); snapshots = `tmutil listlocalsnapshots`; purgeable = `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity`; unreadable = `errorCount` (skipped paths); delta = unexplained remainder.

### 3.d Base 1024 / locale (A10, J9.5)
- Honest **KiB/MiB** labels *or* a base 10 / 1024 toggle next to the On disk/Logical toggle.
- Unify the locale: `Format.bytes` via localized `MeasurementFormatter`/`ByteCountFormatter`, consistent with `Format.count`.

## 4. Implementation plan

1. Enum `CountingMode { .attribution, .exact }` in `ScanController`, exposed by a toggle (next to On disk/Logical).
2. `DirectoryScanner`: in `.exact` mode, request the hardlink attributes + (optional) private-size; dedup `(dev,ino)`; use `privateSize` instead of `allocSize` for clones if available.
3. **Reconciliation** panel: new component under the treemap (or a tab), fed by `Volume` capacities + `tmutil` (via `ProcessRunner`) + trash size + `errorCount`.
4. `Format.bytes`: KiB/MiB labels (or toggle) + localization.

## 5. Verification

- **Golden tests**: fixture with hardlinks → **Exact** mode == `du -sk` (deduplicated), **Attribution** mode == `du -skl`. Fixture with a `cp -c` clone → Exact mode ≈ private size.
- **Reconciliation**: on a real volume, `scan + trash + snapshots + purgeable + unreadable + delta ≈ used(API)` with a small delta; compare against `df`.
- **Live**: toggle Exact/Attribution → the total changes by the right amount on a hardlink fixture.

## 6. Risks & assumptions

- 🔬 `ATTR_CMNEXT_PRIVATESIZE`: availability, buffer cost, exact semantics on partial clones — **to prototype**.
- 🔬 Packing order of extended attributes (`forkattr`) in the bulk buffer — same caution as for A1 (`dirattr`).
- Reconciliation depends on `tmutil` (access rights to snapshots) and on the accuracy of `purgeable` (Apple approximation).

## 7. Effort & dependencies

**2–3 days** (A3 ~½ d, A4 uncertain ~½–1 d, reconciliation ~1 d, formatting ~¼ d). Independent. A **product** decision (two modes) as much as a technical one.
