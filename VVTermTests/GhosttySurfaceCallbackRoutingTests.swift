// SPDX-License-Identifier: MIT
//
//  GhosttySurfaceCallbackRoutingTests.swift
//  VVTermTests
//
//  #310 deterministic routing tests. These are the acceptance oracle for the
//  fix: the revived `GhosttyTerminalViewObserverTeardownTests` race test only
//  observes the #302 weak-nil view/token and was green pre-fix on Xcode 26.3,
//  so its green is a smoke signal. These tests drive the exact crash frame
//  synchronously:
//
//    1. create a real surface, capture its handle and callback context;
//    2. drop the last view reference (no `cleanup()`);
//    3. resolve the userdata the way `Ghostty.App.action` does, or feed the
//       terminal so the custom-IO write callback runs with the dead userdata.
//
//  Pre-fix, step 3 reaches `takeUnretainedValue()` on the freed view and
//  crashes in `objc_retain`. Post-fix, the userdata is the retained context and
//  resolves to nil. The tests assert the dead-window state directly
//  (`context.resolve() == nil`, view weak-nil, context still alive) so a green
//  cannot come from never reaching the window.
//
//  DETERMINISM NOTE. A freshly created view is retained by the main-queue
//  action blocks queued during `ghostty_surface_new`; the tests `await
//  Task.yield()` until it deallocates while holding the `Ghostty.Surface`
//  wrapper themselves. Holding the wrapper means no deferred free is scheduled
//  until the test releases it, so the window cannot close behind the test's
//  back and the pump cannot race the assertion.
//
//  TEARDOWN HYGIENE: every test that drops a view releases the wrapper and
//  drains the pending deferred `ghostty_surface_free` before
//  `Ghostty.App.cleanup()` (the weak context box is the completion signal),
//  because `ghostty_app_free` deinitializes registered surfaces and a later
//  surface free would touch the destroyed app.

import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

@Suite(.serialized)
@MainActor
struct GhosttySurfaceCallbackRoutingTests {

    // MARK: - Fixtures

    private final class WeakBox<T: AnyObject> {
        weak var value: T?

        init(_ value: T? = nil) {
            self.value = value
        }
    }

    /// Collects raw custom-IO writes; written from the surface callback thread,
    /// read by the test after a pump.
    private final class WriteCollector {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            chunks.append(data)
        }

        var combinedString: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: chunks.reduce(into: Data()) { $0.append($1) }, as: UTF8.self)
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
    /// `nil` is a real completion signal.
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

    /// Runs the main run loop for a bounded number of turns (delivery flush for
    /// the custom-IO write path).
    private static func pumpMainRunLoop(turns: Int = 10, seconds: TimeInterval = 0.005) {
        for _ in 0..<turns {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }
    }

    /// Builds a `GHOSTTY_ACTION_SET_TITLE` action for a surface target and calls
    /// `Ghostty.App.action` — the exact callback frame from the #310 crash
    /// (`objc_retain ← closure #1 in static Ghostty.App.action`).
    private static func performSetTitleAction(
        appHandle: ghostty_app_t,
        surface handle: ghostty_surface_t,
        title: String
    ) -> Bool {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = handle

        let cchars = title.utf8.map { CChar(bitPattern: $0) }
        return cchars.withUnsafeBufferPointer { buffer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            var setTitle = ghostty_action_set_title_s()
            setTitle.title = buffer.baseAddress
            action.action.set_title = setTitle
            return Ghostty.App.action(appHandle, target: target, action: action)
        }
    }

    // MARK: - action routing (the acceptance oracle)

    /// The deterministic route test: a `SET_TITLE` surface action in the
    /// dead-view window must resolve to nil (no UAF, no resurrected view).
    ///
    /// Pre-fix this crashes at
    /// `Unmanaged<GhosttyTerminalView>.fromOpaque(...).takeUnretainedValue()`
    /// (`Ghostty.App.swift`'s action fallback); the counterfactual measurement
    /// is recorded in the PR note. Post-fix the context resolves nil and the
    /// action is handled as "title without a terminal view".
    @Test
    func actionInTheDeadViewWindowResolvesToNilWithoutCrashing() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        var heldSurface: Ghostty.Surface?
        var handle: ghostty_surface_t?
        // Evaluated inside the drop scope but stored as plain Bools: a
        // `#expect` referencing `terminal` in that scope would keep the view
        // alive in swift-testing's captured operand record.
        var contextResolvedLiveView = false
        var userdataIsContext = false

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "action-dead-window")
            weakView.value = terminal
            guard let surface = terminal.surface, let cHandle = surface.unsafeCValue else { return }
            heldSurface = surface
            handle = cHandle
            weakContext.value = surface.callbackContext
            contextResolvedLiveView = surface.callbackContext.resolve() === terminal
            userdataIsContext = ghostty_surface_userdata(cHandle) == surface.callbackContext.userdata
        }

        #expect(contextResolvedLiveView, "the context must resolve the live view before the drop")
        #expect(userdataIsContext, "the surface userdata must be the context before the view is dropped")
        guard let handle else {
            Issue.record("surface creation failed")
            return
        }

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")

        // Resolve through the surface's userdata exactly as the action fallback
        // does; the transient context reference dies with the expression so the
        // weak box can drain after the wrapper is released.
        let contextView = Ghostty.SurfaceCallbackContext
            .fromOpaque(ghostty_surface_userdata(handle))?
            .resolve()
        #expect(contextView == nil, "the dead view must resolve to nil")
        #expect(weakContext.value != nil, "the held surface wrapper must keep the context alive")

        let handled = Self.performSetTitleAction(appHandle: appHandle, surface: handle, title: "uaf-probe")
        #expect(handled, "SET_TITLE must be handled in the dead-view window instead of crashing")

        // Release the wrapper: deinit invalidates and queues the deferred free,
        // which retains the context until it has run.
        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
    }

    // MARK: - custom-IO write callback routing

    /// Positive control for the write path: with the view alive, an OSC color
    /// query still reaches the view's write callback. This is the live-path
    /// regression guard for the routing change.
    @Test
    func writeCallbackDeliversWhileTheViewIsAlive() throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "write-live")
        defer { terminal.cleanup() }

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)

        let collector = WriteCollector()
        terminal.writeCallback = { collector.append($0) }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        surface.feedText("\u{1B}]10;?\u{07}")
        Self.pumpMainRunLoop()

        #expect(
            collector.combinedString.contains("\u{1B}]10;rgb:"),
            "the live write callback must still receive the OSC 10 response"
        )
    }

    /// Invalidate suppression with an observable side effect: once the context
    /// is invalidated, the write callback must drop the response even though
    /// the view is still alive.
    @Test
    func writeCallbackIsSuppressedWhenTheContextIsInvalidated() throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "write-invalidated")
        defer { terminal.cleanup() }

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)
        let context = surface.callbackContext

        let collector = WriteCollector()
        terminal.writeCallback = { collector.append($0) }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        // Positive control first: delivery works before invalidation.
        surface.feedText("\u{1B}]10;?\u{07}")
        Self.pumpMainRunLoop()
        let deliveredBefore = collector.combinedString
        #expect(deliveredBefore.contains("\u{1B}]10;rgb:"), "positive control: the response is delivered while valid")

        context.invalidate()
        surface.feedText("\u{1B}]11;?\u{07}")
        Self.pumpMainRunLoop()
        #expect(
            collector.combinedString == deliveredBefore,
            "an invalidated context must suppress further write-callback delivery"
        )
    }

    /// Sibling-site dead-window oracle: after the view is dropped, feeding the
    /// still-alive surface invokes the custom-IO write callback with the dead
    /// userdata. Pre-fix that callback retains the freed view; post-fix the
    /// context resolves nil and the response is dropped.
    @Test
    func writeCallbackInTheDeadViewWindowResolvesToNilWithoutCrashing() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        var heldSurface: Ghostty.Surface?
        var handle: ghostty_surface_t?
        var liveDeliveryWorked = false

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "write-dead-window")
            weakView.value = terminal
            guard let surface = terminal.surface, let cHandle = surface.unsafeCValue else { return }
            heldSurface = surface
            handle = cHandle
            weakContext.value = surface.callbackContext

            let collector = WriteCollector()
            terminal.writeCallback = { collector.append($0) }
            terminal.setupWriteCallback()
            terminal.acceptsTerminalInput = true

            // Positive control: the same feed path delivers while the view is
            // alive, so the dead-window feed below exercises a working channel.
            surface.feedText("\u{1B}]10;?\u{07}")
            Self.pumpMainRunLoop()
            liveDeliveryWorked = collector.combinedString.contains("\u{1B}]10;rgb:")
        }

        #expect(liveDeliveryWorked, "positive control: the write callback delivers while the view is alive")
        guard let handle else {
            Issue.record("surface creation failed")
            return
        }

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")

        let contextView = Ghostty.SurfaceCallbackContext
            .fromOpaque(ghostty_surface_userdata(handle))?
            .resolve()
        #expect(contextView == nil, "the dead view must resolve to nil")
        #expect(weakContext.value != nil, "the held surface wrapper must keep the context alive")

        // The write callback's userdata is the context; feeding here runs it
        // synchronously with the view already gone. Pre-fix: freed-view retain.
        var bytes = Array("\u{1B}]10;?\u{07}".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_surface_feed_data(handle, buffer.baseAddress, buffer.count)
        }

        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
    }
}
