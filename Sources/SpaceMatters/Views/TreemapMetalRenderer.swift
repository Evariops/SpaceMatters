import Metal
import QuartzCore
import simd

// GPU renderer for the treemap tiles (SPEC-09). The engine is 3D-native from the
// start — instanced 3D quads, an MVP camera and a depth buffer — but the current
// view is its *orthographic top-down projection*: flat tiles (height 0) seen from
// straight above, the classic 2D treemap. Going 3D later is a camera + height
// change, not a rewrite (SPEC-09 §9).
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
    /// NDC +1→−1. The full-view camera passes the whole bounds; an animated zoom passes a
    /// shrinking/growing sub-rect so the map pushes toward (or pulls back from) a folder.
    /// Ortho of flat tiles preserves proportions, so the map reads as plain 2D.
    /// z is a constant mid-depth; the Y column stays 0 until boxes extrude.
    static func ortho(viewport v: CGRect) -> Camera {
        let vw = max(Double(v.width), 1), vh = max(Double(v.height), 1)
        let vx = Double(v.minX), vy = Double(v.minY)
        let col0 = SIMD4<Float>(Float(2 / vw), 0, 0, 0)                 // X → clip.x
        let col1 = SIMD4<Float>(0, 0, 0, 0)                            // Y (height) → nothing yet
        let col2 = SIMD4<Float>(0, Float(-2 / vh), 0, 0)               // Z → clip.y (top-left flip)
        let col3 = SIMD4<Float>(Float(-2 * vx / vw - 1),               // translation + constant depth
                                Float(2 * vy / vh + 1), 0.5, 1)
        return Camera(viewProjection: simd_float4x4(col0, col1, col2, col3))
    }
}

/// Uniforms shared by both shader stages. Matches the MSL `Uniforms` (80 bytes).
private struct Uniforms {
    var viewProj: simd_float4x4
    var borderColor: SIMD4<Float>
}

final class TreemapMetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    // Triple-buffered instance storage: the CPU never rewrites a buffer the GPU is
    // still reading. Each slot's buffer is grown (never shrunk) to fit the tile count.
    private static let maxInflight = 3
    private let inflight = DispatchSemaphore(value: maxInflight)
    private var instanceBuffers: [MTLBuffer?]
    private var frameIndex = 0

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
    }

    /// Draw `instances` into `layer` (clearing to `clearColor`). Safe to call with an
    /// empty array — it just clears, so an empty tree shows the background.
    func render(into layer: CAMetalLayer, instances: [TileInstance], camera: Camera,
                clearColor: SIMD4<Float>, borderColor: SIMD4<Float>) {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureAttachments(size)
        guard let drawable = layer.nextDrawable() else { return }

        inflight.wait()
        frameIndex = (frameIndex + 1) % Self.maxInflight
        let buffer = instances.isEmpty ? nil : ensureInstanceBuffer(slot: frameIndex, count: instances.count)
        if let buffer {
            instances.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }

        var uniforms = Uniforms(viewProj: camera.viewProjection, borderColor: borderColor)

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
        if let buffer {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 4-vertex triangle strip (a unit quad), one instance per tile.
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instances.count)
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

    private func ensureInstanceBuffer(slot: Int, count: Int) -> MTLBuffer? {
        let needed = count * MemoryLayout<TileInstance>.stride
        if let buf = instanceBuffers[slot], buf.length >= needed { return buf }
        // Grow with headroom so a slowly-growing tile count doesn't reallocate every frame.
        let buf = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
        instanceBuffers[slot] = buf
        return buf
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
    };
    struct VOut {
        float4 pos [[position]];
        float2 uv;
        float2 tileSize;   // on-screen extent in points (width, depth)
        float  dim;
        float4 color;
    };

    // A unit quad from the vertex id (triangle strip 0..3), placed by the instance and
    // projected by the camera. Today height = 0 → a flat quad on the ground plane.
    vertex VOut treemapVertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              const device TileInstance* inst [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
        float fu = float(vid & 1);
        float fv = float((vid >> 1) & 1);
        TileInstance t = inst[iid];
        float3 world = float3(t.origin.x + fu * t.size.x, 0.0, t.origin.z + fv * t.size.z);
        VOut o;
        o.pos = u.viewProj * float4(world, 1.0);
        o.uv = float2(fu, fv);
        o.tileSize = float2(t.size.x, t.size.z);
        o.dim = t.size.w;
        o.color = t.color;
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
