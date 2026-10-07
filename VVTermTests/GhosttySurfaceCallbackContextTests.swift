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

    // MARK: - Pending clipboard request registry (#329)

    /// #329 registry contract: a registered request is claimable exactly once;
    /// a second claim of the same pointer must return false so a completion
    /// cannot issue a second C call for the same request state.
    @Test
    func registryClaimRemovesEachPendingRequestExactlyOnce() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-claim")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let first = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }

        #expect(context.registerPendingClipboardRequest(state: first, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.registerPendingClipboardRequest(state: second, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.claimPendingClipboardRequest(first), "the first claim must consume the entry")
        #expect(context.claimPendingClipboardRequest(first) == false, "a second claim must fail")
        #expect(context.claimPendingClipboardRequest(second), "the other entry must still be claimable")
        #expect(context.drainPendingClipboardRequests().isEmpty, "every claim must remove exactly its own entry")
    }

    /// #329 registry contract: the drain removes what is pending once and
    /// returns nothing on the second call — the property that makes a teardown
    /// drain idempotent.
    @Test
    func registryDrainReturnsRemainingEntriesOnceAndThenEmpties() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-drain")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let first = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let second = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            first.deallocate()
            second.deallocate()
        }

        #expect(context.registerPendingClipboardRequest(state: first, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.registerPendingClipboardRequest(state: second, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.claimPendingClipboardRequest(first))

        let drained = context.drainPendingClipboardRequests()
        #expect(drained.count == 1, "the drain must return the remaining entry once")
        #expect(drained.first?.state == second)
        #expect(context.drainPendingClipboardRequests().isEmpty, "a second drain must return nothing")
    }

    /// #329 registry contract: `invalidate()` must not clear the registry, and
    /// the drain must ignore `isValid`. This is the load-bearing invariant of
    /// the deferred `deinit` path, which invalidates the context synchronously
    /// and drains later on the main queue.
    @Test
    func registryDrainReturnsEntriesAfterInvalidation() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-invalidate-drain")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let pending = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { pending.deallocate() }

        #expect(context.registerPendingClipboardRequest(state: pending, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        context.invalidate()
        #expect(context.resolve() == nil, "positive control: invalidation must suppress resolution")

        let drained = context.drainPendingClipboardRequests()
        #expect(drained.count == 1, "invalidate() must not clear the registry: the deferred drain still owes a release")
        #expect(drained.first?.state == pending)
        #expect(drained.first?.kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE)
    }

    /// #329 registry contract: a registration that arrives after invalidation
    /// is a no-op — no free path can drain an entry added after the context
    /// died, so admitting one would retain the core's request state forever.
    @Test
    func registryRegisterAfterInvalidationIsANoOp() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-late-register")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let late = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { late.deallocate() }

        context.invalidate()
        #expect(
            context.registerPendingClipboardRequest(state: late, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE) == false,
            "register must report false once the context is invalid"
        )
        #expect(context.drainPendingClipboardRequests().isEmpty, "an invalidated context must not accept new entries")
    }

    /// #329 registry contract: the drain's returned pairs carry the registered
    /// kind, so the teardown telemetry and the deny completion can label each
    /// release correctly.
    @Test
    func registryDrainCarriesTheRegisteredKind() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-kinds")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let paste = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let osc52Read = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            paste.deallocate()
            osc52Read.deallocate()
        }

        #expect(context.registerPendingClipboardRequest(state: paste, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.registerPendingClipboardRequest(state: osc52Read, kind: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ))

        let drained = context.drainPendingClipboardRequests()
        let kinds = Dictionary(uniqueKeysWithValues: drained.map { ($0.state, $0.kind) })
        #expect(kinds[paste] == GHOSTTY_CLIPBOARD_REQUEST_PASTE)
        #expect(kinds[osc52Read] == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ)
    }

    /// #329 registry contract: a multi-entry drain returns every pending entry
    /// in one snapshot — the `teardownDrains` telemetry order is unspecified
    /// for more than one entry, so only set-equality is contractual.
    @Test
    func registryDrainReturnsEveryPendingEntryInOneSnapshot() throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "context-registry-multi-drain")
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let context = try #require(terminal.surface?.callbackContext)
        let paste = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let osc52Read = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer {
            paste.deallocate()
            osc52Read.deallocate()
        }

        #expect(context.registerPendingClipboardRequest(state: paste, kind: GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        #expect(context.registerPendingClipboardRequest(state: osc52Read, kind: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ))

        let drained = context.drainPendingClipboardRequests()
        #expect(drained.count == 2, "the drain must return both pending entries in one snapshot")
        #expect(
            Set(drained.map(\.state)) == Set([paste, osc52Read]),
            "the drain must return exactly the registered request states"
        )
        #expect(context.drainPendingClipboardRequests().isEmpty, "a second drain must return nothing")
    }
}
