import Metal
import QuartzCore
import simd

// GPU renderer for the treemap tiles (SPEC-09, extended by SPEC-10). The engine is
// 3D-native from the start — instanced 3D quads, an MVP camera and a depth buffer —
// but the current view is its *orthographic top-down projection*: flat tiles
// (height 0) seen from straight above, the classic 2D treemap. Going 3D later is a
// camera + height change, not a rewrite (SPEC-09 §9).
//
// SPEC-10 additions: a camera-only draw path that re-uses the last uploaded
// instances (a pan/zoom/resize frame writes no buffer at all), and a second
// per-instance buffer + `morph` uniform so every re-bake of the world is an
// animated interpolation instead of a teleport.
//
// Only the tile *fill* is the GPU's job; layout, colour source, hit-testing and the
// selection/hover overlay live in `TreemapNSView`. One `drawPrimitives(instanceCount:)`
// draws every tile in a single call — the answer to "thousands of CPU fillRect".

/// One tile, as uploaded to the GPU. 3D-native: `origin`/`size` carry a Y (height)
/// axis that is 0 today (flat quad on the XZ ground plane) and becomes `f(size|count)`
/// when tiles extrude into boxes. Layout matches the MSL `TileInstance` (48 bytes).
struct TileInstance {
    /// World position, top-left corner: (x, y=0, z). `w` is padding.
    var origin: SIMD4<Float>
    /// Extent: (width, height=0, depth, dim). `dim` (0…1) folds the highlight/search
    /// dimming into the instance so no second fill pass is needed.
    var size: SIMD4<Float>
    /// Straight sRGB RGBA (opaque; alpha = 1).
    var color: SIMD4<Float>
}

/// View × projection, as a single matrix. Today an orthographic top-down camera;
/// swapping in a perspective + orbit camera is all the 3D transition needs on this side.
struct Camera {
    var viewProjection: simd_float4x4

    /// Orthographic top-down mapping the world rect `viewport` (points, top-left) exactly
    /// onto the drawable: worldX vx→vx+vw to NDC −1→+1, worldZ vy→vy+vh (top→bottom) to
    /// NDC +1→−1. The full-view camera passes the whole bounds; a moving camera (pan,
    /// zoom, animated fit) passes any sub-rect — same instances, different matrix.
    /// Ortho of flat tiles preserves proportions, so the map reads as plain 2D.
    /// z is a constant mid-depth; the Y column stays 0 until boxes extrude.
    static func ortho(viewport v: CGRect) -> Camera {
        let vw = max(Double(v.width), .leastNormalMagnitude), vh = max(Double(v.height), .leastNormalMagnitude)
        let vx = Double(v.minX), vy = Double(v.minY)
        let col0 = SIMD4<Float>(Float(2 / vw), 0, 0, 0)                 // X → clip.x
        let col1 = SIMD4<Float>(0, 0, 0, 0)                            // Y (height) → nothing yet
        let col2 = SIMD4<Float>(0, Float(-2 / vh), 0, 0)               // Z → clip.y (top-left flip)
        let col3 = SIMD4<Float>(Float(-2 * vx / vw - 1),               // translation + constant depth
                                Float(2 * vy / vh + 1), 0.5, 1)
        return Camera(viewProjection: simd_float4x4(col0, col1, col2, col3))
    }
}

/// Uniforms shared by both shader stages. Matches the MSL `Uniforms` (96 bytes).
private struct Uniforms {
    var viewProj: simd_float4x4
    var borderColor: SIMD4<Float>
    /// x = morph progress t (0 → previous instances, 1 → current).
    /// y/z = screen points per world unit (camera scale, per axis) — converts tile
    /// extents to on-screen points for the cushion/border thresholds, so borders
    /// keep a constant screen width at any zoom. w reserved.
    var morph: SIMD4<Float>
}

final class TreemapMetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    // Triple-buffered instance storage: the CPU never rewrites a buffer the GPU is
    // still reading. Slots rotate ONLY when new data is uploaded — camera-only
    // frames rebind the last slot untouched. The queue completes in order, so by
    // the time a slot comes around again (two uploads later, ≥1 semaphore wait),
    // every draw that referenced it has completed.
    private static let maxInflight = 3
    private let inflight = DispatchSemaphore(value: maxInflight)
    private var instanceBuffers: [MTLBuffer?]
    private var prevBuffers: [MTLBuffer?]
    private var slot = 0
    private var boundInstances: MTLBuffer?
    private var boundPrev: MTLBuffer?
    private var instanceCount = 0

    private let transientStorage: MTLStorageMode
    private var depthTexture: MTLTexture?
    private var attachmentSize = CGSize.zero

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        // SwiftPM (no Xcode Metal build step) → compile the shader source at launch.
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vfn = library.makeFunction(name: "treemapVertex"),
              let ffn = library.makeFunction(name: "treemapFragment") else { return nil }

        // No MSAA: every edge in the map is axis-aligned and the tile borders are
        // anti-aliased in the fragment shader, so multisampling had nothing to smooth
        // (verified by eye at 1× vs 4× on Retina). Revisit when the 3D camera lands —
        // perspective brings diagonals.
        let transient: MTLStorageMode = device.supportsFamily(.apple2) ? .memoryless : .private

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm   // non-sRGB: colours arrive sRGB-encoded, stored as-is
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        // Coplanar flat tiles never overlap, so `.lessEqual` (equal-z fragments pass,
        // painter's order wins) keeps shared edges seam-free; ready for real depth in 3D.
        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .lessEqual
        dsd.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: dsd) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.transientStorage = transient
        self.instanceBuffers = Array(repeating: nil, count: Self.maxInflight)
        self.prevBuffers = Array(repeating: nil, count: Self.maxInflight)
    }

    /// Upload a new tile set (rotating the buffer slot). `previous` must be index-
    /// aligned with `instances` (the morph pairing); pass `nil` when there is
    /// nothing to morph from — draws then run with t = 1 against the same buffer.
    /// Upload happens under the same in-flight discipline as draws (see `draw`).
    func upload(instances: [TileInstance], previous: [TileInstance]?) {
        slot = (slot + 1) % Self.maxInflight
        instanceCount = instances.count
        boundInstances = instances.isEmpty ? nil : copy(instances, into: &instanceBuffers[slot], slot: slot)
        if let previous, previous.count == instances.count, !previous.isEmpty {
            boundPrev = copy(previous, into: &prevBuffers[slot], slot: slot)
        } else {
            boundPrev = nil
        }
    }

    private func copy(_ data: [TileInstance], into store: inout MTLBuffer?, slot: Int) -> MTLBuffer? {
        let needed = data.count * MemoryLayout<TileInstance>.stride
        if store == nil || store!.length < needed {
            // Grow with headroom so a slowly-growing tile count doesn't reallocate every frame.
            store = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
        }
        guard let buffer = store else { return nil }
        data.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        return buffer
    }

    /// Draw the last uploaded instances into `layer`. A camera-only frame calls this
    /// alone — no buffer writes, just a new matrix (and morph progress). `contentSize`
    /// is the displayed pixel size; when the drawable is pooled larger than the view
    /// (SPEC-10 §3.6) the viewport clamps rendering to the visible region.
    func draw(into layer: CAMetalLayer,
              camera: Camera,
              pointsPerUnit: (sx: CGFloat, sy: CGFloat) = (1, 1),
              morph: Float = 1,
              clearColor: SIMD4<Float>,
              borderColor: SIMD4<Float>,
              contentSize: CGSize? = nil) {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureAttachments(size)
        guard let drawable = layer.nextDrawable() else { return }

        inflight.wait()

        var uniforms = Uniforms(viewProj: camera.viewProjection,
                                borderColor: borderColor,
                                morph: SIMD4<Float>(boundPrev == nil ? 1 : morph,
                                                    Float(pointsPerUnit.sx), Float(pointsPerUnit.sy), 0))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearColor.x), green: Double(clearColor.y), blue: Double(clearColor.z), alpha: 1)
        rpd.depthAttachment.texture = depthTexture
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1
        // The transient attachments may be larger than the drawable (grow-only
        // allocation on non-memoryless GPUs): clamp the pass to the drawable.
        rpd.renderTargetWidth = drawable.texture.width
        rpd.renderTargetHeight = drawable.texture.height

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inflight.signal()
            return
        }
        if let buffer = boundInstances, instanceCount > 0 {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            // Pooled drawable: draw only into the displayed region; contentsRect crops.
            let content = contentSize ?? size
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(min(content.width, size.width)),
                                        height: Double(min(content.height, size.height)),
                                        znear: 0, zfar: 1))
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBuffer(boundPrev ?? buffer, offset: 0, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 4-vertex triangle strip (a unit quad), one instance per tile.
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instanceCount)
        }
        enc.endEncoding()
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        // `presentsWithTransaction` (set on the layer for smooth live-resize): present
        // synchronously, inside the current CATransaction, so the drawable and the view
        // bounds update atomically — no lag/tearing behind the window during a drag.
        if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }

    private func ensureAttachments(_ size: CGSize) {
        guard depthTexture == nil || attachmentSize != size else { return }
        var w = max(1, Int(size.width)), h = max(1, Int(size.height))
        // Memoryless attachments (Apple Silicon TBDR) cost nothing to recreate.
        // On `.private` (Intel/eGPU) they are real VRAM allocations, recreated
        // twice per frame of a resize drag: round up to 256 px steps and never
        // shrink, so a drag reallocates a handful of times instead; the render
        // pass is clamped to the drawable via renderTargetWidth/Height.
        if transientStorage == .private {
            w = (w + 255) & ~255
            h = (h + 255) & ~255
            if let t = depthTexture, t.width >= w, t.height >= h {
                attachmentSize = size
                return
            }
        }

        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = transientStorage
        depthTexture = device.makeTexture(descriptor: dd)
        attachmentSize = size
    }

    // MARK: - Shader (MSL, compiled at launch)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TileInstance {
        float4 origin;   // x, y(=0), z, _
        float4 size;     // width, height(=0), depth, dim
        float4 color;    // sRGB rgba (opaque)
    };
    struct Uniforms {
        float4x4 viewProj;
        float4   borderColor;
        float4   morph;      // x = t (0 = previous, 1 = current), yz = points per world unit
    };
    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float2 tileSize;   // on-screen extent in points (width, depth)
        float  dim;
        float4 color;
    };

    // A unit quad from the vertex id (triangle strip 0..3), placed by the instance
    // (morph-interpolated between the previous and current sets) and projected by
    // the camera. Today height = 0 → a flat quad on the ground plane.
    vertex VOut treemapVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device TileInstance* inst [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]],
                              const device TileInstance* prev [[buffer(2)]]) {
        float fu = float(vid & 1);
        float fv = float((vid >> 1) & 1);
        float t = u.morph.x;
        TileInstance a = prev[iid];
        TileInstance b = inst[iid];
        float4 origin = mix(a.origin, b.origin, t);
        float4 size   = mix(a.size,   b.size,   t);
        float4 color  = mix(a.color,  b.color,  t);
        float3 world = float3(origin.x + fu * size.x, 0.0, origin.z + fv * size.z);
        VOut o;
        o.pos = u.viewProj * float4(world, 1.0);
        o.uv = float2(fu, fv);
        // Screen-point extents: world units × camera scale — the cushion/border
        // thresholds stay in points, so their look is zoom-invariant.
        o.tileSize = float2(size.x * u.morph.y, size.z * u.morph.z);
        o.dim = size.w;
        o.color = color;
        return o;
    }

    // Fill → cushion sheen (light top → dark bottom, 3 stops) → dim (highlight/search)
    // → border. All per-pixel, all free on the GPU.
    fragment float4 treemapFragment(VOut in [[stage_in]],
                                    constant Uniforms& u [[buffer(1)]]) {
        float3 col = in.color.rgb;
        float minSide = min(in.tileSize.x, in.tileSize.y);

        // Cushion: white a=.16 @0 → 0 @.45 → black a=.20 @1, over the fill. Skip tiny tiles.
        if (minSide > 6.0) {
            float v = in.uv.y;
            float a; float3 sheen;
            if (v < 0.45) { a = mix(0.16, 0.0, v / 0.45); sheen = float3(1.0); }
            else          { a = mix(0.0, 0.20, (v - 0.45) / 0.55); sheen = float3(0.0); }
            col = mix(col, sheen, a);
        }

        // Dim non-matching tiles (folded into the instance): black at 72%, matching CG.
        if (in.dim > 0.0) { col = mix(col, float3(0.0), 0.72 * in.dim); }

        // Border: a ~0.6pt anti-aliased edge in the tile's own colour of `treemapBorder`.
        if (minSide > 3.0) {
            float2 dpt = min(in.uv, 1.0 - in.uv) * in.tileSize; // distance to nearest edge, points
            float edge = min(dpt.x, dpt.y);
            float e = 1.0 - smoothstep(0.1, 1.1, edge);
            col = mix(col, u.borderColor.rgb, u.borderColor.a * e);
        }

        return float4(col, 1.0);
    }
    """
}
