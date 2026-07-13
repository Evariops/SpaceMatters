# SPEC-13 — Sunburst view: the polar projection of the world (GPU, progressive, interaction parity)

> **Request**: a dotMemory-style sunburst as a second map mode — always progressive, always GPU-rendered, with the same interactions as the treemap, and **fed by the same data so switching modes never re-scans**.
> **Status**: ✅ **IMPLEMENTED** (branch `feat/sunburst-view`). Builds directly on SPEC-09 (GPU renderer) and SPEC-10 (persistent world + camera + LOD + morph); generalises nothing new in the model layer.

## 1. Objective

A second projection of the scanned tree: depth becomes concentric rings, size becomes angular extent, the current zoom root becomes the hole in the middle (name + total inside, like dotMemory's retained-size centre). One toggle in the map pane switches projections instantly — same `ScanController`, same `FSNode` tree, same `version`/`zoomRoot`/`selection`/search/type-highlight state. The sunburst must hold the SPEC-10 bar: camera moves are matrix-only frames, structural changes morph instead of teleporting, detail follows the camera (LOD), and a live scan streams into the wheel at tick rate.

## 2. Current state of the code it builds on (verified)

- **The world pattern**: [TreemapWorld](../../Sources/SpaceMatters/Views/TreemapWorld.swift) — per-node entries with parent-relative geometry, ε-stable revalidation ("local moves"), LOD walk over the visible rect, morph pairing by tile identity.
- **The renderer pattern**: [TreemapMetalRenderer](../../Sources/SpaceMatters/Views/TreemapMetalRenderer.swift) — one instanced draw call, triple-buffered instances, previous-buffer + `morph` uniform, camera-only frames that write no buffer.
- **The item source**: [TreemapLayout.buildItems](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L209) — a node's children + own-files block, weighted and sorted descending. Both projections consume exactly this.
- **The controller contract**: `version`, `zoomRoot`/`zoomRequestID`, `selection`, `selectedExt`, `searchMatchIDs`, `zoom(into:)`/`zoomOut()`/`reveal(_:)` — the whole navigation surface is view-agnostic already.

## 3. Design

### 3.1 `SunburstWorld` — angles are the new rects
[SunburstWorld](../../Sources/SpaceMatters/Views/SunburstWorld.swift) mirrors `TreemapWorld`, polar:

- Each node's entry stores its children's spans **parent-relative, as fractions of the parent span** — never absolute, never window-dependent. Absolute spans compose down the ancestor chain (`worldSpan(of:root:)`), exactly like `worldRect(of:root:)`.
- **ε-revalidation**: the discrete decision is the *sibling order* (weights sorted descending). A version bump re-flows exact spans while share drift stays ≤ 2 %; past ε the order re-decides — a local move, animated by the caller's morph. Entries are keyed by node and survive re-roots (diving is a layout-root change, not a new world).
- **Rings**: the world is a fixed 1000×1000 square (the disc is aspect-free — resize never re-bakes). Ring `d` starts at `hole + (R − hole)(1 − k^d)` with `k = 0.8`: thickness decays geometrically, the series converges to the disc edge, so **an arbitrarily deep tree fits inside a finite disc** — outer generations are simply too thin to draw until the camera closes in. Depth is a rendering decision, as SPEC-10 demands.
- **LOD**: expand a node's children when its projected arc length at the children's ring crosses `expandArc` (14 pt), collapse below `collapseArc` (8 pt), hysteresis in between; skip rings thinner than 2.5 pt; cull arcs shorter than 0.5 pt. The visibility test uses the **subtree's** sector (through to the disc edge): descendants extend radially outward, so they can be on screen while the node's own ring is not — the polar difference from the treemap's "children inside the parent rect".
- **Tail underlay**: weights descend, so the first sub-pixel child means the rest of the ring is sub-pixel too — one aggregate remainder arc in the parent's colour closes the ring (same cure as the treemap's under-children tile; without it every ring showed a background wedge before noon).
- **File LOD**: a block arc subdivides into individual file arcs above 400 pt (SPEC-05 generalised, polar edition), same LRU + pending-retry scheme.

### 3.2 `SunburstMetalRenderer` — bounding quad + polar SDF
[SunburstMetalRenderer](../../Sources/SpaceMatters/Views/SunburstMetalRenderer.swift) keeps the SPEC-09 discipline (triple buffering, morph buffer pair, camera-only draws) with different geometry: each arc is its world-space **bounding quad**, and the fragment shader carves the annular sector by signed distance in polar coordinates (radial + angular edge distances, in screen points). That distance drives coverage alpha (anti-aliasing of the curved edges — no MSAA), the ~0.6 pt border tint, the radial cushion (the treemap ramp, light inner → dark outer), and the highlight/search dim. Blending is on, there is no depth buffer (arcs are 2D; the list arrives in painter's order). During a morph the quad is the **union** of the previous and current sectors, so the interpolated shape never clips; angles/radii/colour lerp in the shader.

### 3.3 `SunburstNSView` — isotropic camera, explicit re-root
[SunburstView](../../Sources/SpaceMatters/Views/SunburstView.swift) mirrors `TreemapNSView` with two deliberate differences:

- **The camera is isotropic** — circles must stay circles. The viewport always has the view's aspect and letterboxes the square world (`fitRect`); zoom/pan/clamp/scale-preserving-resize all preserve the equality. No aspect re-bake exists at all.
- **`zoomRoot` is not derived from the camera.** The wheel re-roots explicitly (double-click an arc, double-click the hole/background to pull back, breadcrumb, outline, ⌘↑) — the shared arcs sweep to their new spans (the signature dotMemory animation, which falls out of the generic morph pairing). The free camera is inspection on top; deriving the root from it would re-layout under the user's fingers.

Everything else is parity: hover pill (same chrome), click reveals, right-click menu (same items via [MapContextMenu](../../Sources/SpaceMatters/Views/MapChrome.swift)), scroll pan / pinch & wheel zoom toward the cursor, selection spotlight (even-odd sector dim from the node's span through the rim), search/type dimming folded into instances, live-scan ticks teleport while scanning and morph after — the SPEC-10 policy verbatim. The hole is drawn in the overlay (panel disc + hairline + CoreText name/total scaled to its projected size) and hit-tests as the display root.

### 3.4 One scan, two projections
The toggle ([MapModePicker](../../Sources/SpaceMatters/Views/ContentView.swift), `@AppStorage("mapMode")`) swaps the SwiftUI subview; both read the same controller observables, so **switching is instant and re-scans nothing** — zoom root, selection, search and highlight all carry over. Shared chrome (hover pill, unavailable state, menus, a11y summary) moved to [MapChrome.swift](../../Sources/SpaceMatters/Views/MapChrome.swift); the colour semantics are the treemap's exact palette (hue = dominant type, brightness = relative weight) so the wheel matches the File-types legend and the type-highlight interaction keeps meaning across modes.

### 3.5 Decisions ⚖️
- **Geometric ring decay** over constant thickness: constant rings either clip deep trees or shrink everything; decay gives dotMemory's look (outer rings visibly thinner) *and* makes zoom-reveals-depth true by construction.
- **Type-hue palette** over dotMemory's hue-by-angle rainbow: colour already means "file type" app-wide (legend, treemap, highlight); the sorted-by-size wheel reads rainbow-ish anyway.
- **A separate renderer class** over generalising `TreemapMetalRenderer`: the shared part is ~80 lines of buffer rotation; the instance formats, uniforms, blending and depth policies all differ. Keeping the flagship renderer untouched beat deduplicating it.

## 4. Verification

- `swift test`: **116 tests green**, including 8 sunburst property tests ([SunburstWorldTests](../../Tests/SpaceMattersTests/SunburstWorldTests.swift)): ring partition (contiguous, largest-first, share-exact), camera independence, ε order-keeping vs re-decide, re-root + `worldSpan` composition, ring monotonicity/boundedness, LOD hysteresis, sub-pixel tail closure, seam-safe polar containment and bbox tightness.
- Live run (debug bundle, `--open` on this repo): wheel renders with hole label, multi-ring LOD, palette/legend agreement, borders + cushion; scan stats identical across modes. Driven-gesture verification (dive morph, camera zoom, spotlight) was cut short — synthetic clicks landed in the foreground browser once the user retook the machine — so the gesture checklist below is manual:
  - double-click arc → re-root morph; double-click hole/background → pull back;
  - wheel/pinch zoom toward cursor reveals deeper rings; scroll pans; resize letterboxes;
  - hover pill + outline (arcs and hole); right-click menu; list/breadcrumb sync both ways;
  - search and type-highlight dim; selection spotlights the sector; theme toggle recolours.

## 5. Risks & assumptions 🔬

- **Angular AA at extreme zoom**: arc params are Float on the GPU; edge distances multiply by up to the 10⁶× viewport clamp. Same envelope philosophy as the treemap's floating origin; no shimmer seen at realistic zooms — re-check if the clamp ever loosens.
- **Noon seam**: the first and last arcs each draw their own border at 12 o'clock, reading as one continuous radial line hole→rim (dotMemory shows the same). Cosmetic; a half-border at the two seam edges would hide it if it ever grates.
- **Mode switch recreates the NSView**: the camera resets to fit and world entries rebuild lazily on the next build. Cheap (entries are per-visible-node) and matches "opening the view"; promote both views to a persistent pair only if switching ever feels lossy.

## 6. Effort & dependencies

Done in one pass on `feat/sunburst-view` (~1 500 new lines + shared-chrome extraction). Depends on SPEC-09/SPEC-10 (shipped). Follow-ups that inherit for free later: the 3D extrusion path (SPEC-09 §9) never applied to the sunburst — it stays 2D by design.
