# SPEC-08 — Complete accessibility & internationalization

> **Findings**: J10.1 (VoiceOver), J10.2 (color blindness), J10.3 (fixed text sizes), J10.4 + J9.5 (i18n, mixed locale).
> **Status**: ✅ VoiceOver completed · ✅ color blindness/F6 · ✅ J9.5 · 🔬 J10.3 & complete translation = documented dedicated workstreams.

## 0. Implementation result

- **VoiceOver (J10.1 completed)**: labels/values added on — *Size metric* / *Counting mode* pickers, theme toggle, *Storage reconciliation* button, *File types* rows (name + size + count, button/selection trait), *breadcrumb* segments (name + size + "current/zoom"), **volume cards** (label+value "N% full"), **K8s gauge** (`N percent, OK/High/Critical`). The **treemap** (opaque Canvas) now exposes a spoken summary: zoomed folder + its largest children in %. Adds to the 1st pass (stats, list rows, zoom-out).
- **Color blindness (J10.2)**: the **percentage in text** is a safe redundant channel on the volume gauges (live-verified "81% · …"), and a **textual level** `OK/High/Critical` (`Theme.usageLevel`) in accessibility. **F6 fixed**: thresholds **unified 70/90** everywhere (`Theme.usageColor`) — volumes and K8s were 70/90 vs 70/85.
- **i18n — J9.5 fixed** (SPEC-03): `Format.bytes` is **localized** (decimal separator), consistent with `Format.count` — no more mixed locale (live-verified: "85,7 GiB").

## 0.b Remaining dedicated workstreams (honest)

- **🔬 J10.3 (text scaling / Dynamic Type)**: the app uses **fixed** `.system(size:)` sizes by density choice; making them responsive to "Larger Text" is a **global design retrofit** (≈200 sites) that must be calibrated so as not to break the dense layout — dedicated workstream, not a bolt-on (consistent with the "design robustness" stance). Not attempted on the fly.
- **🔬 J10.4 (complete translation)**: the mixed-locale **bug** (J9.5) is fixed; **translation** into other languages (populated String Catalog `.xcstrings`) is a full-fledged localization effort, out of scope for v1.

## 1. Objective

Make the app usable with a screen reader, robust to color blindness and text-size preferences, and ready for localization.

## 2. Current state (verified)

- **J10.1 (first pass delivered)**: `accessibilityLabel/Value` added on the stats bar, the list rows ("Folder sub1, 979 KB" — **read live via the AX API**), the treemap (root zoom + size) and the zoom-out button. The rest of the content (treemap = `Canvas`, individual tiles) remains opaque.
- Color: "file type" info carried by the **hue alone** (16 hues, collisions); green/orange/red gauges with no fallback shape/text (J10.2).
- Fixed type 9–13 pt, no reaction to the system text size (J10.3).
- Everything hardcoded in English; `Format.count` localized but `Format.bytes` not (J9.5, mixed locale).

## 3. Implementation plan

1. **VoiceOver (complete J10.1)**:
   - Toolbar buttons (Home/Rescan/theme): `accessibilityLabel`.
   - Treemap: expose the tiles as `accessibilityChildren` (or a rotor) with label "name, size, % of parent" — allows navigating the map via keyboard/VoiceOver.
   - File types panel, breadcrumb, K8s gauges: labels + values.
   - (SPEC-01 synergy: an `NSTableView` provides accessible selection/focus/rotor natively.)
2. **Color blindness (J10.2)**: do not rely on the hue alone — add the **% in text** on the gauges, a light pattern/wave or a type label on the tiles on hover, and check the contrasts. Unify the color thresholds (70/90 % VolumeCard vs 70/85 % K8s, cf. F6).
3. **Text size (J10.3)**: global scale factor in `Theme` driven by the system preference (or a setting), applied to the font sizes.
4. **i18n (J10.4, J9.5)**: String Catalog (`.xcstrings`) for the strings; `Format.bytes` via a **localized** formatter (consistent with `Format.count`); decide KiB/MiB vs base 10 (cf. SPEC-03).

## 4. Verification

- **Live (established method)**: read the app's AX tree (`osascript` System Events) → each control exposes a relevant label/value; navigate the treemap via the rotor.
- Manual VoiceOver test; color-blindness simulator (Sim Daltonism); "Larger Text".

## 5. Risks & assumptions

- 🔬 Expose the `Canvas` treemap tiles to AX without degrading the rendering (overlay of invisible accessibility elements vs `accessibilityRepresentation`).
- i18n: the current locale mix (J9.5) is the first bug to fix before any translation.

## 6. Effort & dependencies

**1–2 days.** The VoiceOver part benefits from SPEC-01 (native list). Independent otherwise.
