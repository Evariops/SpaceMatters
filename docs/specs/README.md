# Specifications by workstream — MacDirStats

Each `SPEC-*.md` is a self-contained requirements document for a deferred workstream from the [action plan](../../PLAN-ACTION.md), written to be picked up in a dedicated session. Common format:

1. **Objective & findings covered** — the why, with references to the audits.
2. **Current state of the code (verified)** — what exists, cited `file:line`.
3. **Design axes & tradeoffs** — real options, with a justified recommendation.
4. **Implementation plan** — files, steps.
5. **Verification** — tests + live driving (the screenshot + coordinate-click method is established and works).
6. **Risks & assumptions (🔬)** — what remains to be proven.
7. **Effort & dependencies**.

Guiding principle (carried over from the plan): **integrity > performance > robustness > simplicity > maintainability**, long-term first.

| Spec | Workstream | Findings | Effort | Depends on |
|---|---|---|---|---|
| [SPEC-01](SPEC-01-keyboard-navigation.md) | Keyboard navigation & native list | J3.1, J4.2, J3.7 | 1–2 d | — |
| [SPEC-02](SPEC-02-invalidation-rescan.md) | Sub-tree invalidation & re-scan | B1(cure), A6, A7, J4.4, D1 | 1–2 d | — |
| [SPEC-03](SPEC-03-exact-vs-attribution.md) | Exact counting vs attribution + reconciliation | A3, A4, A10, J9 | 2–3 d | — |
| [SPEC-04](SPEC-04-fsevents-live.md) | FSEvents — live dashboard | S3, J5.2, J4.5, D1 | 1–2 d | SPEC-02 |
| [SPEC-05](SPEC-05-file-level-treemap.md) | File-level refinement **on zoom** (per-folder overview) | S5 | 2–3 d | — |
| [SPEC-06](SPEC-06-pluggable-backends.md) | Pluggable backends | S6 | ~1 d/backend | — |
| [SPEC-07](SPEC-07-distribution.md) | **Signed/notarized DMG distribution via GitHub** (v1) | J1.1–J1.5, D4 | 1–2 d | — |
| [SPEC-08](SPEC-08-accessibility.md) | Full accessibility & i18n | J10.1–J10.4, J9.5 | 1–2 d | SPEC-01 (partial) |
| [SPEC-09](SPEC-09-gpu-treemap-rendering.md) | **3D-native** GPU treemap rendering (Metal, ortho 2D projection) | perf-resize (PR #17) | 2–3 d | PR #17 (NSView seam, done) |

**Recommended order**: SPEC-02 (unblocks SPEC-04 and closes A6/A7 cleanly) → SPEC-01 → SPEC-03 → SPEC-08 → SPEC-04 → SPEC-05/06/07 depending on product priorities.
