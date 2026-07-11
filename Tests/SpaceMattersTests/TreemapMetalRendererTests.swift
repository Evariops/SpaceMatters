import Testing
import Metal
@testable import SpaceMatters

/// The treemap shader is MSL source compiled at launch (SwiftPM has no Metal build
/// step), so a broken shader edit can't fail the build — only the runtime init. The
/// GPU renderer is the *only* tile renderer (no CG fallback), so that failure must
/// be caught here, on any machine that has a Metal device, not discovered in the app.
struct TreemapMetalRendererTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rendererInitialisesOnMetalHardware() {
        #expect(TreemapMetalRenderer() != nil,
                "shader compile or pipeline creation failed — the treemap cannot render")
    }
}
