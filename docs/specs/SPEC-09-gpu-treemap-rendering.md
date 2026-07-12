# SPEC-09 — **3D-native** GPU rendering of the treemap (Metal, orthographic 2D projection)

> **Findings**: **perf-resize** workstream (continuation of PR #17 "solution C"). Profiling: after removing the SwiftUI tax (`NSHostingView.layout` 5373→101, `dispatchActions` 3395→1), the cost shifted onto the **CPU rasterization** of the tiles — `CGContextFillRect` ≈ 7482 samples during a drag, on the `NSEventThread`. On a pathological tree (`.build/ModuleCache`, thousands of tiny tiles) the per-tile fill remains the floor.
> **Architecture decision (enacted)**: the rendering engine is **3D-native from the start** — real 3D geometry, camera, MVP matrices, depth buffer. The current display is its **top-down orthographic projection**: flat tiles (height = 0) viewed straight-on → **strict iso-visual** with the current 2D visualization. An ortho projection of flat tiles **preserves proportions exactly** (no vanishing lines), so today's 2D is mathematically identical. **Switching to 3D** (later, §9) = changing the **camera** (perspective + orbit) and giving a **height** to the tiles — **no rewrite**, the pipeline is already 3D.
> **Product constraint**: **we keep the current 2D tiles.** The 3D stays **deferred (+3–6 months)** on the product side.
> **Status**: 📋 **PROPOSED** — to be planned. The seam (NSView separating layout/interaction from `draw()`) is already in place (PR #17), which makes the Metal renderer a **local replacement** of the tile drawing only.

## 1. Objective

Render the treemap on the **GPU** instead of the CPU, via a **native 3D pipeline** whose current rendering is an **orthographic 2D projection**, so that resize (and eventually zoom, then 3D) is smooth even on tens of thousands of tiles — **without touching the visual or the interaction today**. The reasoning, proven on this project:

- The old `Canvas` + `.drawingGroup()` was smooth **because it went through the GPU** (Metal offscreen); its real cost was the **SwiftUI reconcile tax** around it, not the drawing.
- Solution C (PR #17) removed that tax (AppKit drives the resize) but **brought the drawing back onto the CPU** (`CALayer.draw` → Core Graphics).
- **Metal = both gains at once**: GPU drawing **and** no SwiftUI tax.

A treemap is a set of axis-aligned colored quads: the textbook case for **GPU instancing** (a single draw call for N tiles). The sequential filling of thousands of rects on a thread becomes an upload of N instances + **one** draw call, rasterized in parallel.

## 2. Current state of the code (verified)

Seam (laid by PR #17) — the drawing is **already isolated** from the rest:

- [TreemapView.swift:13](../../Sources/SpaceMatters/Views/TreemapView.swift#L13) `struct TreemapView` (SwiftUI wrapper: observation + hover overlay + a11y) → [:70](../../Sources/SpaceMatters/Views/TreemapView.swift#L70) `TreemapRepresentable: NSViewRepresentable` → [:110](../../Sources/SpaceMatters/Views/TreemapView.swift#L110) `final class TreemapNSView: NSView, CALayerDelegate`.
- Two `CALayer`: [:133](../../Sources/SpaceMatters/Views/TreemapView.swift#L133) `tileLayer` (tiles, redrawn on relayout) + [:134](../../Sources/SpaceMatters/Views/TreemapView.swift#L134) `overlayLayer` (hover + selection, redrawn alone).
- **The bottleneck**: [`drawTiles`](../../Sources/SpaceMatters/Views/TreemapView.swift#L387) — per-tile loop with [`ctx.setFillColor` + `ctx.fill(r)`](../../Sources/SpaceMatters/Views/TreemapView.swift#L398-L399), [`drawLinearGradient` per tile](../../Sources/SpaceMatters/Views/TreemapView.swift#L405) (cushion), dim fill, border `stroke`. **All on CPU.**
- Current pixel-cost workaround: [`viewWillStartLiveResize` sets `contentsScale` to 1](../../Sources/SpaceMatters/Views/TreemapView.swift#L208) (¼ of the pixels during the drag, re-sharpened at the end). A band-aid — Metal makes it unnecessary (§4.7).
- Orientation: top-left rects, bottom-left CG context → [`flip(_:_:)` per tile](../../Sources/SpaceMatters/Views/TreemapView.swift#L383). Historical bug (vertically inverted hover) fixed on the hit-test side [:490](../../Sources/SpaceMatters/Views/TreemapView.swift#L490).

What **does not move** (and is therefore not rewritten):

- **Layout**: [`TreemapLayout.compute`](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L77) + size-independent [`Cache`](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L49) + [`squarifySorted`](../../Sources/SpaceMatters/Views/TreemapLayout.swift#L192); only the **placement** re-runs per frame, the sorted structure is memoized. Stays CPU (cheap after cache). Driven by [`ScanController.treemapLayout`](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L453), invalidated by [`version`](../../Sources/SpaceMatters/ViewModel/ScanController.swift#L30).
- **Colors**: [`computeColors`](../../Sources/SpaceMatters/Views/TreemapView.swift#L302) + LUT `(hueIndex, bucket luminance)` → today `CGColor` ([`cgColor(for:weight:)`](../../Sources/SpaceMatters/Views/TreemapView.swift#L326)), via [`Theme.treemapTypeColor(hueIndex:weight:)`](../../Sources/SpaceMatters/App/Theme.swift#L61). **Only change**: emit **packed RGBA** (`SIMD4<Float>`) instead of `CGColor`.
- **Interaction**: [`tileAt`](../../Sources/SpaceMatters/Views/TreemapView.swift#L490), hover ([:507](../../Sources/SpaceMatters/Views/TreemapView.swift#L507)), `mouseUp` ([:524](../../Sources/SpaceMatters/Views/TreemapView.swift#L524)), `menu(for:)` ([:568](../../Sources/SpaceMatters/Views/TreemapView.swift#L568)) — **unchanged** (CPU hit-test on `tiles`).
- **Current overlay**: [`drawOverlay`](../../Sources/SpaceMatters/Views/TreemapView.swift#L432) (1 spotlight + 1 rim + 1 outline) in CoreGraphics — **migrates to a 2nd Metal pass** (§4.5); the CG code stays as a fallback.

No Metal usage today (grep: only a residual `.drawingGroup()` in `KubernetesResultView`, off-topic).

## 3. Retained design

The renderer is an **instanced-quad Metal pipeline, 3D-native, projected in ortho 2D**. The decisions, each enacted:

1. **GPU instancing** — a unit quad (generated from `[[vertex_id]]`, no VBO) drawn **N times** via `drawPrimitives(instanceCount: N)`; each instance reads its `{origin, size, color}` from an **instance buffer** indexed by `[[instance_id]]`. A single draw call for all the tiles. *(Equivalent OpenGL model: `glDrawArraysInstanced` + per-instance attribute; MSL instead of GLSL, pre-compiled pipeline state instead of the mutable global state.)*

2. **3D-native, ortho projection** — 3D vertices, **MVP matrix** driven by a camera, depth buffer active. Today: `height = 0`, top-down orthographic camera → pixel-identical output to the 2D. This choice has **the same per-frame cost** as a frozen 2D pipeline, but makes the 3D (§9) free (camera + height) instead of a rewrite. The MVP matrix replaces the per-tile `flip(_:_:)` (flip encoded once in the camera).

3. **On-demand rendering** — `CAMetalLayer` driven manually (draw called from `setFrameSize`/`apply`), GPU at rest when nothing changes. No `MTKView` (avoids a subview + delegate; we keep our single `NSView` and its interaction).

4. **Shared buffer + ring** — `MTLStorageModeShared` (Apple Silicon unified memory: CPU writes, GPU reads, **zero copy/blit**). Ring of 2–3 buffers + `DispatchSemaphore` so that the CPU does not overwrite a buffer still being read by the GPU (useful during the burst of frames of a live-resize).

5. **Borders via inset gutter** — clear the layer to `treemapBorder`, then draw each fill **inset by 0.6 px** → the border color shows through as gutters. Zero border geometry, a crisp "grid" look (the classic treemap trick).

6. **Overlay = 2nd Metal pass** — selection + hover rendered by a handful of instances, border/dim in a **fragment shader** (SDF). This is *the* place for future highlight effects (§4.8); putting it in Metal now avoids writing a CPU overlay that we would then tear out. **Phase 1: reproduces the current look identically.**

## 4. Implementation plan

Principle: **replace only the guts of the drawing**. Layout, colors (source), hit-test and interaction stay as they are.

### 4.1 New file `Views/TreemapMetalRenderer.swift`
Encapsulates all the Metal, testable/replaceable, without polluting `TreemapNSView`:
- `device: MTLDevice`, `commandQueue`, `pipelineState: MTLRenderPipelineState`, `depthState: MTLDepthStencilState`, ring of `instanceBuffers: [MTLBuffer]`, `inflightSemaphore`, a `Camera` (§4.2).
- **3D-native** instance struct (compact, aligned):
  ```
  struct TileInstance {          // 48 B: 3× SIMD4<Float>
      var origin: SIMD4<Float>   // x, y, z(=0) in world space; w = padding
      var size:   SIMD4<Float>   // width, depth, height(=0 today), w = padding
      var color:  SIMD4<Float>   // linear RGBA; the dim is already folded in
  }
  ```
  Today `origin.z = 0` and `size.height = 0` → each instance is a **flat quad** laid on the ground plane; tomorrow `size.height = f(size|count|depth)` → an **extruded box**, **same struct**.
- `func render(instances:, drawable:, camera: Camera, borderColor:)`.

### 4.2 Camera & world convention (the heart of 3D-native)
- **World**: **XZ ground plane** (like a map / a city), **Y = height** axis ("code city": the tiles lie on the ground, the boxes rise in Y). The squarify layout (top-left rects in pixels) is mapped onto the ground plane by a fixed transform (scale + top-left → world flip).
- **Camera** = `view` (position/orientation) × `projection`, encapsulated in `Camera { viewProjection() -> float4x4 }`. **Today**: **orthographic** camera, above, looking straight down (−Y), *up* aligned to reproduce the rects layout → top-down ortho = the 2D rects to the pixel (iso-visual guarantee).
- **Depth buffer** enabled right now (`MTLDepthStencilState`, `.depth32Float`): inert as long as the tiles are flat, **ready** for box occlusion in 3D. Negligible cost.

### 4.3 Shaders `Views/Treemap.metal`
- **Vertex**: quad vertex (`vertex_id` → 2 triangles; tomorrow 12 box triangles) placed by `instance.origin/size`, transformed into clip space by the **camera MVP** (uniform). Passes `uv∈[0,1]` and the pixel size to the fragment.
- **Fragment**: `fill = instance.color`; **cushion** = reproduction of the current 3 stops ([TreemapView.swift:160-165](../../Sources/SpaceMatters/Views/TreemapView.swift#L160-L165)) — white α .16 at the top → 0 at 0.45 → black α .20 at the bottom, composited over the fill, **skipped** if tile < 6 px (as today); **border** via inset gutter (background pre-cleared to `treemapBorder`, fill inset by 0.6 px). sRGB output (§6).

### 4.4 Instance buffer — allocation discipline
- Reuse one `MTLBuffer` per ring slot, **grown only** when `tiles.count` exceeds capacity (like `sizeScratch`). Never a per-frame alloc.
- Filling: single loop over `tiles`, sub-pixel culling **on the CPU side before writing** (we don't send a tile ≤ 0.5 px — already filtered [:395](../../Sources/SpaceMatters/Views/TreemapView.swift#L395)). Direct write into the shared buffer.
- Colors: `computeColors` produces `SIMD4<Float>` (same values as `treemapTypeColor`, converted once) instead of `CGColor`. The **dim** (highlight/search) is **folded** into the color at fill time → a simple recompute of the buffer on a highlight change (infrequent), no second pass.

### 4.5 Integration into `TreemapNSView`
- Replace `tileLayer` (CPU CALayer) with a `CAMetalLayer` (`tileMetalLayer`), `device` assigned, `pixelFormat` calibrated (§6), `framebufferOnly = true`, `presentsWithTransaction = true` (§6 resize gotcha).
- `relayout()`/`apply()` unchanged in their logic; at the end, instead of `tileLayer.setNeedsDisplay()` → synchronous `renderer.render(...)`.
- `setFrameSize`: update `tileMetalLayer.drawableSize = bounds.size * scale`, then render. **Remove** the live-resize `contentsScale = 1` hack (§4.7).
- **Overlay** (selection + hover): 2nd Metal pass in the same drawable (spotlight `evenOdd` → inside/outside test + SDF rim; hover outline → SDF). **Phase 1: current look identically.** The CG `drawOverlay` stays as a fallback (§4.6).

### 4.6 Fallback (defensive)
If `MTLCreateSystemDefaultDevice()` returns `nil` (never on macOS 15, but by-the-book) → keep the current CoreGraphics path (`drawTiles`/`drawOverlay`) as a fallback. The CG drawing code **is not deleted**, it becomes plan B → **no regression possible**.

### 4.7 Expected bonus: removal of the live-resize band-aid
Metal rasterizes the full retina almost for free → no more need for `contentsScale = 1` during the drag ([:208-217](../../Sources/SpaceMatters/Views/TreemapView.swift#L208-L217)). The treemap stays **sharp during** the resize, not only at the end.

### 4.8 Effects headroom — unlocked by §4.5, **out of scope** (Phase 2)
Once borders/selection/hover are in a fragment shader, these effects become changes to a uniform, unaffordable on CPU per frame — **do NOT turn them on in Phase 1** (would break the iso-visual). Recorded as a product cap, to be scoped in a dedicated workstream: animated selection glow (distance falloff + `time`), anti-aliased SDF borders, animated dim (150 ms fade), search matches that "breathe". *(Animated effects imply a 60 fps rendering bounded by `CADisplayLink` for the duration of the transition — not a continuous loop.)*

## 5. Verification

- **Iso-visual (established screenshot method)**: side-by-side capture **before (CG) / after (Metal)** on the same scan — colors, cushion sheen, gutters, dim (highlight extension + search), selection spotlight, hover outline. Must be indistinguishable (sRGB tolerance, §6).
- **Orientation**: re-verify the historical bug — hovering the tiles **at the top** correctly highlights those at the top (the flip is now in the projection).
- **Perf (goal of the workstream)**: `sample`/Instruments (Metal System Trace) on `.build/ModuleCache` during a continuous drag → CPU rasterization (`CGContextFillRect`) **disappears** from the profile; GPU frame time < 1 ms; `NSEventThread` offloaded.
- **Interaction**: click (reveal), double-click (zoom/open/zoomOut), context menu, selection from the list → **unchanged** (CPU hit-test untouched).
- **Tests**: the tested logic (`TreemapLayout`, `squarify*`) is unchanged → existing tests green. Add a unit test on the **instance packing** (N tiles → N expected `TileInstance`, sub-pixel culling applied) — pure, no GPU.

## 6. Risks & assumptions (🔬)

- 🔬 **Color space**: CG draws in sRGB device RGB; the Metal drawable must match (`.bgra8Unorm_srgb` vs gamma conversion in the shader). Poorly calibrated → tiles lighter/darker. To lock down in capture before generalizing.
- 🔬 **`CAMetalLayer` + live-resize**: without `presentsWithTransaction = true` + **synchronous** presentation (`commit` → `waitUntilScheduled` → `drawable.present()` in the same transaction as the bounds change), the Metal layer **lags/tears** behind the window during the drag. This is THE gotcha; to be handled from the start.
- 🔬 **Inset border**: opaque `treemapBorder` gutter vs the current semi-transparent 0.6 px stroke. Validate in capture; possible fallback to an SDF border (fragment shader) if the difference displeases.
- **CPU placement as the new floor**: once GPU raster is free, the residual per-frame cost becomes `squarifySorted` (O(n) arith + rect alloc). If measured as bothersome: reuse the rect buffers, or even parallelize — **out of scope**, to be measured afterward.
- **Intel Macs** (macOS 15, minority): `storageModeShared` OK but less optimal; not blocking.

## 7. Effort & dependencies

**2–3 days.** Independent. The NSView seam of PR #17 is the prerequisite — **already in place**. No external dependency (Metal is system). The current CG code stays as a fallback, so no regression possible in case of a device issue.

## 8. Scope — what this SPEC does / does NOT do

**Does**: a **3D-native** renderer (3D geometry, camera, MVP, depth) rendered in **orthographic 2D projection**, iso-visual with the current tiles, on GPU. Tiles **and** overlay (selection/hover) in Metal.
**Does NOT** (today):
- No visible change: visualization, palette, layout, interaction **unchanged**. **Strict iso-visual.**
- No text in the tiles (stayed removed).
- **No animated effects**: the Metal overlay reproduces the current look identically; the shader headroom (§4.8) is unlocked but **off** — that's Phase 2.
- No height ≠ 0, no perspective camera, no orbit: the **3D stays unplugged** (top-down ortho camera, `size.height = 0`). See §9.

## 9. 3D activation — deferred on the **product** side (+3–6 months), already **architected**

The 3D is **not** a future overhaul workstream, it's a **configuration switch** of an already-3D engine. Nothing to rewrite — we "re-plug" what §4.2 laid down:

- **Camera**: `projection` ortho → **perspective**; `view` top-down → **tilted + orbitable**. Pipeline, shaders, instance buffer: identical.
- **Height**: `size.height` goes from 0 to `f(data)` → the flat quads become **boxes** (the vertex shader goes from 2 to 12 triangles; same instance struct).
- **Depth buffer**: already active (§4.2) → correct box occlusion without changing anything.
- **Cushion → shading**: the top→bottom sheen becomes real lighting by face normal — same location in the fragment shader.

Candidate dimensions for the height: `size(metric)`, `fileCount` ([FSNode.swift:28](../../Sources/SpaceMatters/Model/FSNode.swift#L28)), tree depth. ⚠️ **`FSNode` has no temporal field** (verified: identical to `main`) — an "age/freshness" height would imply adding `mtime` to the scan (dependency to be scoped separately, out of this SPEC).

→ Product decision: **2D tiles now**, 3D activation in 3–6 months. This SPEC guarantees that this activation will be a **camera setting + a height attribute**, not a rewrite.
