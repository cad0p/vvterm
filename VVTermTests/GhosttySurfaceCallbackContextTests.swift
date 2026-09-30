// SPDX-License-Identifier: MIT
//
//  GhosttySurfaceCallbackContextTests.swift
//  VVTermTests
//
//  #310 deterministic unit tests for `Ghostty.SurfaceCallbackContext`: the
//  retained, lock-protected userdata a surface now points at instead of the
//  owning view's address.
//
//  WHAT THIS FILE PROVES (and what it does not):
//    - the surface's `ghostty_surface_userdata` is the context's `userdata`
//      pointer right after creation, and the context resolves the live view
//      (the creation-ordering assertion: the context must be installed before
//      `ghostty_surface_new` returns);
//    - `resolve()` returns nil once the view deallocates (owner death) and once
//      `invalidate()` runs (even while the view is still alive), and
//      invalidation is one-way (it never resurrects);
//    - the deferred `ghostty_surface_free` block retains the context (a weak
//      context box stays non-nil after the block is queued and goes nil only
//      after the main queue drains it), which is what keeps the raw userdata
//      pointer valid across the free.
//
//  DETERMINISM NOTE. A freshly created view is retained by the main-queue
//  action blocks queued during `ghostty_surface_new` (the core emits
//  set_title/cell_size from `Surface.init`, and `Ghostty.App.action` dispatches
//  the delivery asynchronously capturing the resolved view). The drop tests
//  therefore `await Task.yield()` until the view is gone, while holding the
//  `Ghostty.Surface` wrapper themselves. Holding the wrapper means no deferred
//  free is scheduled until the test releases it, so the dead-view window cannot
//  close behind the test's back and the pump cannot race the assertion.
//
//  "invalidate precedes `ghostty_surface_free`" is not observable from
//  end-state assertions (both orderings leave the context invalid), so it is
//  pinned at the source level in
//  `GhosttySurfaceUserdataLifetimePinsTests` (pin P-C). No seam is faked here.

import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttySurfaceCallbackContextTests {

    // MARK: - Fixtures

    /// A weak box so a test can observe a reference's lifetime without becoming
    /// the strong owner that keeps it alive.
    private final class WeakBox<T: AnyObject> {
        weak var value: T?

        init(_ value: T? = nil) {
            self.value = value
        }
    }

    private static func makeTerminal(
        app: Ghostty.App,
        appHandle: ghostty_app_t,
        paneId: String
    ) -> GhosttyTerminalView {
        GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: paneId,
            useCustomIO: true
        )
    }

    /// Yields (so the action blocks queued during surface creation can run and
    /// release their view reference) and pumps the main run loop until the view
    /// deallocates. Safe to pump: the tests that call this hold the
    /// `Ghostty.Surface` wrapper, so no deferred free is scheduled yet.
    private static func waitUntilViewDeallocates(_ box: WeakBox<GhosttyTerminalView>, timeout: TimeInterval = 2.0) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while box.value != nil, Date() < deadline {
            await Task.yield()
            pumpMainRunLoopOnce()
        }
    }

    /// Runs the main run loop until `box.value` is nil or the timeout expires.
    /// On the deferred free path the free block is the context's last owner, so
    /// `nil` is a real completion signal — not a pump that hopes the block ran.
    private static func drainUntilNil(_ box: WeakBox<Ghostty.SurfaceCallbackContext>, timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while box.value != nil, Date() < deadline {
            // The deferred free is a main-queue block; the main actor executor
            // runs queued blocks at the yield, while a bare run-loop pump does
            // not (measured: the free block only runs after a task yield).
            await Task.yield()
            pumpMainRunLoopOnce()
        }
        return box.value == nil
    }

    /// `RunLoop.current.run(until:)` is marked `noasync`, so it cannot sit in an
    /// async function body even behind a guard.
    private static func pumpMainRunLoopOnce() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    // MARK: - Creation ordering

    /// The surface userdata must be the context (not the view address) as soon
    /// as `ghostty_surface_new` returns, and the context must resolve the live
    /// view. This is the assertion behind the creation-ordering constraint: the
    /// core emits `set_title`/`cell_size` from inside `Surface.init`.
    @Test
    func surfaceUserdataIsTheRetainedContextAfterCreation() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-userdata")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface)
        let handle = try #require(surface.unsafeCValue)
        let context = surface.callbackContext

        #expect(
            ghostty_surface_userdata(handle) == context.userdata,
            "the surface userdata must be the retained context's pointer, not the view's address"
        )
        #expect(context.resolve() === terminal, "the context must resolve the live view")
    }

    // MARK: - resolve() semantics

    /// Owner death: once the view is released, `resolve()` must return nil even
    /// though the surface (and therefore the context) is still alive.
    @Test
    func resolveReturnsNilAfterTheViewDeallocates() async throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        var heldSurface: Ghostty.Surface?
        var capturedContext: Ghostty.SurfaceCallbackContext?

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-owner-death")
            weakView.value = terminal
            heldSurface = terminal.surface
            capturedContext = heldSurface?.callbackContext
            weakContext.value = capturedContext
        }

        _ = try #require(heldSurface)
        _ = try #require(capturedContext)

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")
        #expect(capturedContext?.resolve() == nil, "a dead view must resolve to nil, never a dangling pointer")
        #expect(weakContext.value != nil, "the held surface wrapper must keep the context alive")

        // Drop the test's own strong context reference so the weak box can
        // drain, then release the wrapper: deinit invalidates and queues the
        // deferred free, which retains the context until it has run.
        capturedContext = nil
        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
        app.cleanup()
    }

    /// Invalidation: `invalidate()` must suppress resolution even while the
    /// view is alive, and it must be one-way — a second resolve cannot
    /// resurrect the view.
    @Test
    func resolveReturnsNilAfterInvalidateAndNeverResurrects() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-invalidate")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface)
        let context = surface.callbackContext
        #expect(context.resolve() === terminal, "positive control: the context resolves the live view")

        context.invalidate()
        #expect(context.resolve() == nil, "an invalidated context must not resolve the live view")
        context.invalidate()
        #expect(context.resolve() == nil, "invalidation must be one-way: resolve never resurrects")
        #expect(terminal.surface != nil, "the view and surface must still be alive for this assertion to be meaningful")
    }

    /// The deferred free block's retain: when the surface wrapper deinitializes
    /// with the view already gone, the queued `ghostty_surface_free` must keep
    /// the context alive until it runs. Without the capture, the weak box would
    /// go nil immediately and the surface's userdata would dangle on freed
    /// memory.
    @Test
    func deferredFreeBlockKeepsTheContextAliveUntilItRuns() async throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        var heldSurface: Ghostty.Surface?

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-deferred-retain")
            weakView.value = terminal
            heldSurface = terminal.surface
            weakContext.value = heldSurface?.callbackContext
        }

        _ = try #require(heldSurface)
        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate before the wrapper is released")

        heldSurface = nil
        #expect(
            weakContext.value != nil,
            "the deferred free block must retain the context across the queued ghostty_surface_free"
        )
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
        app.cleanup()
    }
}
