import Metal
import QuartzCore
import simd

// GPU renderer for the sunburst arcs (SPEC-13). Same engine philosophy as
// `TreemapMetalRenderer` (SPEC-09/10): one instanced draw call, a camera
// matrix, a second per-instance buffer + `morph` uniform so every structural
// change (scan tick, re-root, LOD split) is an animated interpolation.
//
// The geometry differs: an arc is drawn as its world-space *bounding quad* and
// the annular sector is carved per-pixel in the fragment shader (polar signed
// distance) — which is also what anti-aliases the curved edges, so no MSAA.
// Blending is on (the rim needs coverage alpha) and there is no depth buffer:
// arcs are 2D by nature and the draw list arrives in painter's order.
//
// Only the arc *fill* is the GPU's job; layout, colour, hit-testing and the
// selection/hover overlay live in `SunburstNSView`.

/// One arc, as uploaded to the GPU. Layout matches the MSL `ArcInstance` (48 B).
struct ArcInstance {
    /// Bounding quad in rebased world coordinates (x, y, w, h). During a morph
    /// this covers the union of the previous and current sectors, so the quad
    /// never clips the interpolated shape.
    var bbox: SIMD4<Float>
    /// The sector: (a0, a1) radians in the world's clockwise-from-noon sweep,
    /// (r0, r1) radii in world units.
    var arc: SIMD4<Float>
    /// Straight sRGB rgb; `w` folds the highlight/search dimming (0…1).
    var color: SIMD4<Float>
}

/// Uniforms shared by both shader stages. Matches the MSL `Uniforms` (96 bytes).
private struct Uniforms {
    var viewProj: simd_float4x4
    var borderColor: SIMD4<Float>
    /// x = morph progress t (0 → previous instances, 1 → current).
    /// y = screen points per world unit (isotropic camera).
    /// zw = disc centre, rebased world coordinates.
    var params: SIMD4<Float>
}

final class SunburstMetalRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    // Triple-buffered instance storage — same in-flight discipline as the
    // treemap renderer: the CPU never rewrites a buffer the GPU is reading,
    // slots rotate only on upload, camera-only frames rebind untouched.
    private static let maxInflight = 3
    private let inflight = DispatchSemaphore(value: maxInflight)
    private var instanceBuffers: [MTLBuffer?]
    private var prevBuffers: [MTLBuffer?]
    private var slot = 0
    private var boundInstances: MTLBuffer?
    private var boundPrev: MTLBuffer?
    private var instanceCount = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        // SwiftPM (no Xcode Metal build step) → compile the shader source at launch.
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vfn = library.makeFunction(name: "sunburstVertex"),
              let ffn = library.makeFunction(name: "sunburstFragment") else { return nil }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm   // non-sRGB: colours arrive sRGB-encoded
        // Coverage alpha from the polar SDF is what anti-aliases the curved
        // edges — classic source-over blending onto the cleared background.
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.instanceBuffers = Array(repeating: nil, count: Self.maxInflight)
        self.prevBuffers = Array(repeating: nil, count: Self.maxInflight)
    }

    /// Upload a new arc set (rotating the buffer slot). `previous` must be
    /// index-aligned with `instances` (the morph pairing); pass `nil` when there
    /// is nothing to morph from — draws then run with t = 1.
    func upload(instances: [ArcInstance], previous: [ArcInstance]?) {
        slot = (slot + 1) % Self.maxInflight
        instanceCount = instances.count
        boundInstances = instances.isEmpty ? nil : copy(instances, into: &instanceBuffers[slot])
        if let previous, previous.count == instances.count, !previous.isEmpty {
            boundPrev = copy(previous, into: &prevBuffers[slot])
        } else {
            boundPrev = nil
        }
    }

    private func copy(_ data: [ArcInstance], into store: inout MTLBuffer?) -> MTLBuffer? {
        let needed = data.count * MemoryLayout<ArcInstance>.stride
        if store == nil || store!.length < needed {
            // Grow with headroom so a slowly-growing arc count doesn't reallocate every frame.
            store = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
        }
        guard let buffer = store else { return nil }
        data.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        return buffer
    }

    /// Draw the last uploaded instances into `layer`. A camera-only frame calls
    /// this alone — no buffer writes, just a new matrix (and morph progress).
    /// Returns `false` when no frame was presented (zero-sized layer, or the
    /// drawable pool was dry) so the caller can schedule a retry — a dropped
    /// frame here would otherwise leave the map blank until the next data tick.
    @discardableResult
    func draw(into layer: CAMetalLayer,
              camera: Camera,
              pointsPerUnit: CGFloat,
              center: SIMD2<Float>,
              morph: Float = 1,
              clearColor: SIMD4<Float>,
              borderColor: SIMD4<Float>) -> Bool {
        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return false }
        guard let drawable = layer.nextDrawable() else { return false }

        inflight.wait()

        var uniforms = Uniforms(viewProj: camera.viewProjection,
                                borderColor: borderColor,
                                params: SIMD4<Float>(boundPrev == nil ? 1 : morph,
                                                     Float(pointsPerUnit), center.x, center.y))

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearColor.x), green: Double(clearColor.y), blue: Double(clearColor.z), alpha: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inflight.signal()
            return false
        }
        if let buffer = boundInstances, instanceCount > 0 {
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBuffer(boundPrev ?? buffer, offset: 0, index: 2)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 4-vertex triangle strip (the bounding quad), one instance per arc.
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instanceCount)
        }
        enc.endEncoding()
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        // `presentsWithTransaction` (set on the layer for smooth live-resize):
        // present synchronously, inside the current CATransaction — see
        // `TreemapMetalRenderer.draw`.
        if layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
        return true
    }

    // MARK: - Shader (MSL, compiled at launch)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float TWO_PI = 6.28318530718;

    struct ArcInstance {
        float4 bbox;    // x, y, w, h (rebased world; prev∪current during a morph)
        float4 arc;     // a0, a1, r0, r1
        float4 color;   // sRGB rgb, w = dim
    };
    struct Uniforms {
        float4x4 viewProj;
        float4   borderColor;
        float4   params;     // x = morph t, y = points per world unit, zw = centre
    };
    struct VOut {
        float4 pos [[position]];
        float2 world;
        float4 arc;      // lerped (a0, a1, r0, r1)
        float3 color;
        float  dim;
    };

    // The bounding quad from the vertex id (triangle strip 0..3). The quad
    // comes from the *current* instance (the CPU stores the union box there
    // during a morph); the sector params and colour interpolate.
    vertex VOut sunburstVertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               const device ArcInstance* inst [[buffer(0)]],
                               constant Uniforms& u [[buffer(1)]],
                               const device ArcInstance* prev [[buffer(2)]]) {
        float fu = float(vid & 1);
        float fv = float((vid >> 1) & 1);
        float t = u.params.x;
        ArcInstance a = prev[iid];
        ArcInstance b = inst[iid];
        float4 arc = mix(a.arc, b.arc, t);
        float4 colDim = mix(a.color, b.color, t);
        float2 world = float2(b.bbox.x + fu * b.bbox.z, b.bbox.y + fv * b.bbox.w);
        VOut o;
        // World is the XZ ground plane (the treemap camera convention).
        o.pos = u.viewProj * float4(world.x, 0.0, world.y, 1.0);
        o.world = world;
        o.arc = arc;
        o.color = colDim.rgb;
        o.dim = colDim.w;
        return o;
    }

    // Carve the annular sector out of the quad: signed distances to the radial
    // and angular edges, in screen points. The min distance drives coverage
    // alpha (anti-aliasing), the border tint, and everything outside discards.
    fragment float4 sunburstFragment(VOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(1)]]) {
        float s = u.params.y;
        float2 d = in.world - u.params.zw;
        float r = length(d);
        float a0 = in.arc.x, a1 = in.arc.y, r0 = in.arc.z, r1 = in.arc.w;
        float span = a1 - a0;

        // Distance to the ring edges, points (negative outside).
        float dr = min(r - r0, r1 - r) * s;

        // Distance to the angular edges, points — arc length at this radius.
        // A (near-)full circle has no angular edges.
        float da = 1e6;
        if (span < TWO_PI - 1e-3) {
            float theta = atan2(d.y, d.x);
            float t = fmod(theta - a0, TWO_PI);
            if (t < 0.0) { t += TWO_PI; }
            da = min(t, span - t) * max(r, 1e-4) * s;
        }

        float edge = min(dr, da);
        float alpha = clamp(edge + 0.5, 0.0, 1.0);   // ~1pt anti-aliased rim
        if (alpha <= 0.001) { discard_fragment(); }

        float3 col = in.color;

        // Cushion: light inner edge → dark outer edge (the treemap ramp, made
        // radial) — gives the rings their relief. Skip hairline rings.
        float thickness = (r1 - r0) * s;
        if (thickness > 6.0) {
            float v = clamp((r - r0) / max(r1 - r0, 1e-6), 0.0, 1.0);
            float a; float3 sheen;
            if (v < 0.45) { a = mix(0.16, 0.0, v / 0.45); sheen = float3(1.0); }
            else          { a = mix(0.0, 0.20, (v - 0.45) / 0.55); sheen = float3(0.0); }
            col = mix(col, sheen, a);
        }

        // Dim non-matching arcs (highlight/search), matching the treemap's 72%.
        if (in.dim > 0.0) { col = mix(col, float3(0.0), 0.72 * in.dim); }

        // Border: a ~0.6pt anti-aliased edge in the theme's border colour.
        if (thickness > 3.0) {
            float e = 1.0 - smoothstep(0.1, 1.1, edge);
            col = mix(col, u.borderColor.rgb, u.borderColor.a * e);
        }

        return float4(col, alpha);
    }
    """
}
