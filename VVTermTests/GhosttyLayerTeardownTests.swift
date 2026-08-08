import QuartzCore
import Testing
@testable import VVTerm

struct GhosttyLayerTeardownTests {
    @MainActor
    @Test
    func detachesOnlyRendererOwnedSublayers() {
        let host = CALayer()
        let rendererLayer = CALayer()
        let appOwnedLayer = CALayer()
        host.addSublayer(rendererLayer)
        host.addSublayer(appOwnedLayer)

        Ghostty.LayerTeardown.prepare(hostLayer: host) { layer in
            layer === rendererLayer
        }

        #expect(rendererLayer.superlayer == nil)
        #expect(appOwnedLayer.superlayer === host)
    }

    @MainActor
    @Test
    func detachesAllMatchingSublayers() {
        let host = CALayer()
        let rendererA = CALayer()
        let rendererB = CALayer()
        host.addSublayer(rendererA)
        host.addSublayer(rendererB)

        Ghostty.LayerTeardown.prepare(hostLayer: host) { _ in true }

        #expect(rendererA.superlayer == nil)
        #expect(rendererB.superlayer == nil)
        #expect((host.sublayers ?? []).isEmpty)
    }

    @MainActor
    @Test
    func isIdempotentForAlreadyDetachedLayers() {
        let host = CALayer()
        let rendererLayer = CALayer()
        host.addSublayer(rendererLayer)

        Ghostty.LayerTeardown.prepare(hostLayer: host) { _ in true }
        Ghostty.LayerTeardown.prepare(hostLayer: host) { _ in true }

        #expect(rendererLayer.superlayer == nil)
    }

    @MainActor
    @Test
    func leavesHostUntouchedWhenNoRendererLayersMatch() {
        let host = CALayer()
        let appOwnedLayer = CALayer()
        host.addSublayer(appOwnedLayer)

        Ghostty.LayerTeardown.prepare(hostLayer: host) { _ in false }

        #expect(appOwnedLayer.superlayer === host)
        #expect(host.sublayers?.count == 1)
    }

    @MainActor
    @Test
    func handlesNilSublayers() {
        let host = CALayer()

        Ghostty.LayerTeardown.prepare(hostLayer: host) { _ in true }

        #expect((host.sublayers ?? []).isEmpty)
    }
}
