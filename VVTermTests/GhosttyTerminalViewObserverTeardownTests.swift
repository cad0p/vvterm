// SPDX-License-Identifier: MIT
//
//  GhosttyTerminalViewObserverTeardownTests.swift
//  VVTermTests
//
//  #302 runtime regression: a `GhosttyTerminalView` released on a path that
//  never calls `cleanup()` must still remove its `configReloadObserver` token
//  from NotificationCenter.
//
//  WHY THIS IS NOT GREEN BY CONSTRUCTION: the view's `nonisolated deinit` is
//  the only teardown that runs when the last reference is dropped without
//  `cleanup()` (`dismantleUIView` early-returns on `paneStillExists`, then
//  `cleanupPane` / `beginApplicationTermination` drop the registry's last
//  reference). NotificationCenter strongly retains a block-based observer's
//  opaque token until `removeObserver` is called, and the registration block
//  captures `[weak self]`, so the view deallocates while the token survives —
//  exactly what this test observes through a weak box. Before the #302 fix the
//  token assertion fails while the view assertion passes.
//
//  RESIDUAL (stated, not hidden): this path deliberately skips `cleanup()`, so
//  the #116 `LayerTeardown.prepare` step is not exercised (pre-existing, named
//  by #299); and this is a simulator runtime observation, not a device one.
//

import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttyTerminalViewObserverTeardownTests {

    /// A weak box so the test can observe the token's lifetime without
    /// becoming the strong owner that keeps it alive.
    private final class WeakBox {
        weak var value: AnyObject?

        init(_ value: AnyObject? = nil) {
            self.value = value
        }
    }

    @Test
    func viewReleasedWithoutCleanupRemovesItsConfigReloadObserver() async throws {
        let app = Ghostty.App()
        // Runs after the final run-loop pump below, so the deinit's deferred
        // `unregisterSurface` Task and the Surface wrapper's main-queue free
        // fallback drain before `ghostty_app_free`.
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        let weakView = WeakBox()
        let weakToken: WeakBox = autoreleasepool {
            let view = GhosttyTerminalView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                worktreePath: NSTemporaryDirectory(),
                ghosttyApp: appHandle,
                appWrapper: app,
                paneId: "observer-teardown-probe",
                useCustomIO: true
            )
            weakView.value = view
            return Self.mirroredConfigReloadObserver(of: view)
        }

        // Positive controls: the weak boxes saw a live view and a registered
        // token before the view was dropped, so a green run cannot come from
        // the Mirror failing to find the property.
        #expect(weakView.value != nil, "the view must still be alive inside the construction scope")
        #expect(weakToken.value != nil, "the view must have registered configReloadObserver in init")

        // The only strong reference went out of scope above, deliberately
        // without calling `cleanup()`.
        await Self.pumpRunLoop()

        #expect(weakView.value == nil, "the view must deallocate once its last reference is dropped (its deinit must run)")
        #expect(
            weakToken.value == nil,
            "the view's deinit must remove configReloadObserver; a surviving token is the #302 leak (this path never calls cleanup())"
        )

        // Second pump so the deinit's main-queue work drains before the app is
        // freed (the deferred cleanup runs after this point).
        await Self.pumpRunLoop()
    }

    // MARK: - Helpers

    /// Reads the private `configReloadObserver` token into a weak box. The
    /// `Mirror` and the unwrapped token are locals of this call and die with
    /// its frame, so the returned box is the only surviving handle and it is
    /// weak.
    private static func mirroredConfigReloadObserver(of view: GhosttyTerminalView) -> WeakBox {
        let box = WeakBox()
        let mirror = Mirror(reflecting: view)
        if let child = mirror.children.first(where: { $0.label == "configReloadObserver" }),
           let token = child.value as? NSObjectProtocol {
            box.value = token
        }
        return box
    }

    /// Pump the main run loop so a merely-late release is not read as a leak
    /// and the deinit's main-queue work can drain.
    private static func pumpRunLoop() async {
        await Task.yield()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        await Task.yield()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}
