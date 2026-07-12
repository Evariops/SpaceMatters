# SPEC-10 — Persistent world treemap: continuous camera, hierarchical LOD, "map" navigation

> **Findings**: resize profiling from 2026-07-12 (Instruments, Game Performance, release build, M4 Pro) — during a live-drag: **main thread saturated at ~80%**, **~16 ms CPU per presented frame** (120 Hz budget: 8.3 ms) → ~50 effective fps with hitches at 25-46 ms. Breakdown: **~22% app code** (continuous layout ~10%, `tiles` reconstruction/repack ~6%, present ~4% — including **IOSurface creation on every frame**, the changing `drawableSize` invalidating the drawable pool), **~78% AppKit/SwiftUI machinery** (chrome layout, constraints, AttributeGraph — two passes per frame). GPU: **0.3%** utilization, p50 0.13 ms — completely idle.
> **Paradigm flaw observed** (captures at two window sizes): the layout is a **function of the viewport**. Freezing the discrete decisions ([TreemapLayout.Cache](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L57)) makes the resize *monotone*, but the cache is invalidated on every `version` bump (scan tick at 10 Hz, FSEvents refresh) and the decisions are re-decided **at the current window rect** — two invalidations at two sizes → two unrelated worlds, the big blocks change place. The "world" is re-rolled permanently.
> **Architecture decision (proposed)**: invert the paradigm, in the manner of an open-world game engine — **the layout is a pure function of the data, computed in world coordinates; the viewport is only a camera; the level of detail is a rendering decision; data changes are local animated touch-ups, never a global re-roll.** As a product bonus: the treemap becomes **navigable like Google Maps** (trackpad pan, continuous zoom toward the cursor, detail that reveals itself on zoom-in).
> **Prerequisite**: PR #24 (Metal renderer as the sole rendering path, [Camera.ortho](../../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift#L39) already decoupling viewport and instances).
> **Status**: 📋 **PROPOSED** — to be planned. Replaces the "frozen reference" mechanic of SPEC-09/PR #17 with a world model; generalizes SPEC-05; prepares the 3D activation of SPEC-09 §9.

## 1. Objective

That **no** camera interaction (window resize, pan, zoom) recomputes or re-packs anything anymore: one camera frame = one matrix, budget **< 1 ms** CPU main thread. That the **position of a folder in the world be stable** — between two resizes, between two scan ticks, between two refreshes — and that any legitimate structural change (data that moves, aspect that drifts too much) be a **local animated transition**, not a global teleport. And open the product feature: **navigate the disk like a map** — two fingers to move, pinch to dive, level of detail that follows.

## 2. Current state of the code (verified)

What exists and what we build on:

- **The camera already exists**: [Camera.ortho(viewport:)](../../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift#L39) projects an arbitrary world-rect onto the drawable; the zoom animation ([startZoomAnimation](../../Sources/SpaceMatters/Views/TreemapView.swift#L679)) already animates a camera **over frozen instances** — the proof of concept of the model is in the code.
- **Partial freezing exists**: [TreemapLayout.Cache](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L57) memoizes per-node the discrete decisions (row breaks, orientations) and only replays the continuous geometry. Flaws: global invalidation by `(metric, version, root)` ([ScanController.treemapLayout](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L540)), reference = window rect of the moment, and the continuous geometry + [relayout()](../../Sources/SpaceMatters/Views/TreemapView.swift#L399) + [packInstances](../../Sources/SpaceMatters/Views/TreemapView.swift#L442) return **on every frame** of resize.
- **The renderer copies the instances on every render()** (triple buffer) — no "camera only, unchanged buffer" path.
- **The CG overlay doesn't know how to follow the camera** (masked during animated zoom, hover disabled during the animation); the hit-test ([tileAt](../../Sources/SpaceMatters/Views/TreemapView.swift#L599)) is in view coordinates, valid only for camera at identity.
- **SPEC-05**: the files of the sole zoom root are tiles ([filesIn](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L562), `rootFileTiles` memoized); navigation is a **structural state** `zoomRoot` ([zoom(into:)](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L1150)) that re-layouts.
- Scale: typical host scan = **713,695 folders / 3.9 M files** (today's capture); possible depth > 20 levels.

## 3. Retained design

### 3.1 The world: parent-relative hierarchical coordinates
Each node stores its rect **relative to the parent, in [0,1]²** (Float32, 16 B), decided by the squarify on the children's weights — **never in pixels, never a function of the window**. A node's absolute world-rect is the **composition** of its lineage's relative rects, computed in `Double` at render time for the visible sub-trees only. Properties:

- **Stability by construction**: a node's relative rect changes only if the weights of its siblings change — not on resize, not on zoom, not when a distant cousin moves.
- **Precision**: at 4 M files, a deep tile can measure 10⁻⁶ of the world; composing in Double then **camera re-basing** (camera-relative coordinates before Float conversion for the GPU — the game engines' *floating origin*) eliminates the Float32 precision breakage in deep zoom.
- **Storage**: extension of `Cache.Entry` (the per-node entries already exist) — no field added to `FSNode`, the model stays pure. Entries built **lazily** (only for LOD-expanded nodes) and LRU-evicted outside the viewport, like map tiles.

The **world's aspect** lazily follows the window's aspect: during a drag the camera stretches (deformation tolerated, bounded by hysteresis ~±20%); at `viewDidEndLiveResize` or when the threshold is crossed, **animated global re-bake** (morph, §3.4). Decision ⚖️: this is the only event allowed to re-decide globally — and it is **rare and animated**.

### 3.2 The camera: continuous map navigation
`Camera` is enriched with a `(world center, scale)` state with exact view↔world conversions (inverse for the hit-test). Gestures:

- **Pan**: two-finger scroll / drag (hand mode). **Zoom**: pinch and wheel, **toward the cursor** (the point under the mouse stays under the mouse — the Google Maps invariant). **Double-click**: animated zoom-to-fit of the folder (replaces the re-layout of `zoom(into:)` with a camera movement — the current animation becomes *the* navigation). **⌘0 / breadcrumb / Home**: fit of an ancestor.
- **Bounds**: zoom-min = whole world (light rubber-band), zoom-max = when the smallest visible file reaches ~40 px per side.
- **`zoomRoot` becomes a derivative of the camera**: the deepest folder whose world-rect contains ~the viewport. Breadcrumb, list, a11y summary hook onto it as today — the list→map selection does a camera fit, the map→list navigation follows the derivative. The structural state disappears; the mental URL becomes "where is the camera".

### 3.3 Hierarchical LOD by projected size
The static `maxDepth`/`minSide` disappear in favor of a per-node rule, evaluated on the **on-screen projected size** (px = world size × camera scale):

- projected side < **T_collapse** (~8 px) → the folder is rendered **aggregated**: a tile of its `dominantExt` color (the field exists, [FSNode](../../Sources/SpaceMatters/Model/FSNode.swift#L46));
- projected side > **T_expand** (~14 px) → its children are expanded (hysteresis T_expand > T_collapse against *popping* at the threshold edge);
- projected side > **T_files** (~400 px per side) → its **own files** appear as individual tiles — **generalization of SPEC-05**: no longer only the zoom root, any folder large enough on screen. File layouts computed on demand, LRU cache.

The **subdivision is animated**: when a folder expands, its children are born from the parent rect and interpolate toward their rects (morph §3.4) — Google Maps' "tile split"; the inverse on collapse. The GPU instance set is managed in **contiguous ranges per expanded sub-tree**, rebuilt only when the LOD set changes; a camera-only frame **rewrites no buffer** (new `render(cameraOnly:)` path that reuses the last buffer — the current per-frame copy disappears).

### 3.4 Morph: every re-bake is a transition
The vertex shader receives **two instance buffers** (before/after, paired by node) + a uniform `t`; it interpolates origin/size (~200 ms, current easing). Applies to: aspect re-bake (end of drag), **scan ticks and FSEvents refreshes** (coalesced at 10 Hz max — the world "breathes" instead of teleporting, the flaw of the captures disappears by construction), LOD expansion/collapse, future 2D↔3D transition. Orphan instances (deleted node) fade toward size 0; new instances are born from the parent rect.

### 3.5 Stability under scan: local invalidation ("local moves")
The `version` invalidation ceases to be global: the scanner/FSEvents know the **dirty sub-trees** — only their entries (relative rects, decisions) are re-decided; siblings whose weights have drifted only below an **ε** (~2%) keep their decisions (continuous re-geometry only). This is the spirit of "stable treemaps via local moves" (Sondag et al., TVCG 2018) applied to our existing cache. During the initial scan, the world **builds progressively**: entries appear as data arrives (streaming), the LOD bounds what is computed — we never layout 713 k folders at once, only the visible + a margin.

### 3.6 Presentation: drawable pooling, camera-aware overlay
- **Drawable**: `drawableSize` rounded up to the **256 px step**, framed via `contentsRect` → the IOSurface pool survives the drag (the per-frame allocations measured at the profile disappear). 🔬 to validate with `presentsWithTransaction`; fallback = reallocation only at `viewDidEndLiveResize`.
- **Overlay** (selection spotlight + hover): its 2-3 rects move to **world coordinates**, transformed by the camera on each present (trivial cost) → the overlay **follows** pan/zoom/morph, the hover stays active during the movements (the current inhibition goes away). The hit-test goes through the camera inverse (view → world → descent by containment in the relative rects).

## 4. Implementation plan — milestones

**M1 — Frozen world + passive camera (~2-3 days)**: parent-relative rects in `Cache.Entry`; world composition → instances; resize = camera only + animated re-bake at end of drag; `render(cameraOnly:)`; drawable pooling; overlay/hit-test via camera inverse; hover active during movements. *Output: resize 120 Hz, app share ~0 in the profile, no more block jumps on resize.*

**M2 — Map navigation (~2-3 days)**: pan/zoom-toward-cursor (scroll, pinch, wheel), double-click = animated fit, bounds + rubber-band, `zoomRoot` derived (breadcrumb/list/a11y follow), ⌘0/Home = root fit. *Output: the "Google Maps" feature.*

**M3 — Hierarchical LOD + files (~4-5 days)**: projected thresholds + hysteresis, lazy/LRU entries, instance ranges per sub-tree, subdivision-morph, files per folder beyond T_files (generalizes SPEC-05). *Output: zooming in reveals the detail, zooming out aggregates — at unlimited depth.*

**M4 — Streaming & live scan (~3-4 days)**: invalidation by dirty sub-tree, ε-stability of the decisions, morphs coalesced on ticks/FSEvents, progressive construction during the scan. *Output: an ongoing scan is a world that fills in smoothly.*

*(M5 = 3D: out of scope — see §8.)*

## 5. Verification

- **Stability (the bug of the captures)**: reference script — same scan, resize → version tick → resize sequence; the centroids of the 20 largest blocks must not move by > a few % of the world (excluding explicit morphs). Pure unit test on the relative rects: re-layout at different aspects ⇒ identical relative rects.
- **Perf**: Instruments re-profile of the same scenario (protocol of 2026-07-12: attach + warm-up ~10 s to absorb) — camera frame < 1 ms CPU app; zero `CAIOSurfaceCreate` during a drag; presents at the vsync cadence during pan/zoom.
- **Precision**: zoom at max on the smallest file of a 4 M scan — no geometry jitter (validates the camera re-basing).
- **LOD**: repeated threshold crossings (oscillating zoom) without popping or instance churn (hysteresis); LRU entries memory budget bounded and measured.
- **Interaction**: hover/click/menu/selection during pan, zoom **and** morph; breadcrumb consistent with the camera derivative; a11y (dominant folder summary); existing `TreemapLayout` tests green (the squarify itself does not change).

## 6. Risks & assumptions (🔬)

- 🔬 **Float precision in deep zoom** — mitigated by parent-relative + Double composition + camera re-basing; to be proven at milestone M1 (test of §5).
- 🔬 **`contentsRect` × `presentsWithTransaction`** on CAMetalLayer — to validate early; fallback documented (§3.6).
- 🔬 **Before/after morph pairing** under aggressive scan (nodes born/dying in bursts) — 10 Hz coalescing + birth-from-parent should suffice; otherwise degrade to cross-fade.
- 🔬 **Derived `zoomRoot` mental model**: the list and the map may transiently diverge during a pan — the breadcrumb UX "follows the camera" is to be tested (M2 prototype before freezing).
- ⚖️ **Wheel = zoom** (map convention) vs scroll = pan (document convention): decide at M2 (proposal: trackpad pan + pinch zoom, mouse wheel = zoom).
- **Memory**: full entries on a pathological tree — bounded by LOD-lazy + LRU, to measure M3.
- **Deformation during the drag** (world aspect ≠ window in the hysteresis band): assumed, bounded, corrected by the animated re-bake at end of drag.

## 7. Effort & dependencies

**~11-15 days** in 4 milestones deliverable independently (each leaves the app better than before). Depends on: PR #24 merged (Metal-only). No external dependency. The 78% AppKit/SwiftUI tax on *window* resize is **not** in this scope (separate chrome workstream) — but pan/zoom themselves do not touch the window: map navigation runs entirely within the GPU/camera budget.

## 8. Scope — what this SPEC does / does NOT do

**Does**: the world paradigm (layout = data), continuous pan/zoom camera, projected hierarchical LOD (folders **and** files), morphs on every change, streaming under scan, spatial stability guaranteed and tested.
**Does NOT**: 3D (heights, perspective, orbit) — but this model is its **clean prerequisite**: SPEC-09 §9 then activates via camera + height on an unchanged world, the LOD and the morph applying as-is to the boxes. No minimap (nice-to-have, to scope after M2). No SwiftUI chrome overhaul (the 78% of the window-resize profile — separate workstream). The tiles' look (palette, cushion, gutters) does not change.

## 9. Post-implementation addendum (PR #25 — visual QA of 2026-07-12)

Amendments enacted during the implementation, after four passes of visual QA on a real scan (4 M files):

- **§3.6 drawable pooling: abandoned.** The 🔬 was confirmed — the `contentsRect` crop produces black bands during the drag. The documented fallback applies: exact `drawableSize` per frame; the resize having become camera-only, IOSurface reallocation is the only residual cost, assumed.
- **§3.4 subdivision morph: "appear-in-place", not grow-from-parent.** Geometric growth from the parent rect superimposes the children on each other and on their neighbors during the transition (large ghost squares on zoom). New tiles appear at their final place; only the tiles present in both builds slide, and their **colors cross-fade** (the luminosity renormalization fades instead of jumping). A rebuild mid-morph restarts from the displayed state (lerp at t), not from the previous target.
- **§3.4 live scan: teleport, not morph.** At 10 Hz of violent restructurings, 220 ms slides never land — the map disintegrates into scattered squares on the underlayer. An active scan rebuilds instantly (each frame is a coherent tiling); the morphs apply to the calm post-scan life (FSEvents, deletions, metric, aspect re-bake, LOD).
- **§3.5 ε anchored to decision shares + quality guard.** The drift measured against the last revalidation (sliding baseline) let the decisions drift without bound in small steps (10:1 slivers). The ε is measured against the shares **at the moment of the decision**, the aspect drift of the node's rect (±25%) also re-decides, and a self-repairing guard re-decides locally beyond a worst ratio of 5:1.
- **Parent underlayer**: each expanded folder (and subdivided files block) is painted under its children — the culled children (< 0.5 px) show the folder's color instead of punching a hole to the background; hover/click there land on the folder.
- **Normalized wheel**: precise deltas ÷12, factor bounded to [0.5, 2] per event (×1.15/notch, aligned on the pinch).
- Vanished tiles are removed without a fade (fading to zero would imply blending — opaque pipeline preserved).
