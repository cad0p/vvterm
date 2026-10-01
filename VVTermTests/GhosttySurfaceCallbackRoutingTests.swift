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

    /// Test-owned invocation record for the dead-window write probe.
    ///
    /// The production write callback returns before any observable side effect
    /// when the context resolves nil, so the only way to tell "the callback ran
    /// and dropped the response" from "the callback never ran" is a callback the
    /// test owns. The probe carries the surface's real context userdata (passed
    /// through the C userdata, since a C function pointer cannot capture
    /// context) and resolves it through the same production helper the real
    /// callback uses. Written from the termio IO thread, read from the main
    /// actor after a bounded wait.
    private final class WriteCallbackProbe {
        /// The surface's retained context userdata, resolved exactly as the
        /// production write callback resolves it.
        let contextUserdata: UnsafeMutableRawPointer

        private let lock = NSLock()
        private var invocations = 0
        private var dropped = 0
        private var resolvedViews = 0

        init(contextUserdata: UnsafeMutableRawPointer) {
            self.contextUserdata = contextUserdata
        }

        /// Recover the probe from the callback's userdata, mirroring the
        /// production callback's `fromOpaque` shape.
        static func from(_ userdata: UnsafeMutableRawPointer?) -> WriteCallbackProbe? {
            guard let userdata else { return nil }
            return Unmanaged<WriteCallbackProbe>.fromOpaque(userdata).takeUnretainedValue()
        }

        /// Recorded before `resolve()`, so a never-invoked callback cannot look
        /// like a ran-and-dropped one.
        func noteInvocation() {
            lock.lock(); defer { lock.unlock() }
            invocations += 1
        }

        func noteDropped() {
            lock.lock(); defer { lock.unlock() }
            dropped += 1
        }

        func noteResolvedView() {
            lock.lock(); defer { lock.unlock() }
            resolvedViews += 1
        }

        var invocationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return invocations
        }

        var droppedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return dropped
        }

        var resolvedViewCount: Int {
            lock.lock(); defer { lock.unlock() }
            return resolvedViews
        }
    }

    /// Minimal invocation counter for callbacks whose only observable effect is
    /// "it ran" (e.g. `onProcessExit`). The close callback dispatches through a
    /// main-queue block, which a bare run-loop pump does not run, so the tests
    /// wait on this counter through the bounded `waitUntil` helper.
    private final class InvocationSpy {
        private let lock = NSLock()
        private var invocations = 0

        func noteInvocation() {
            lock.lock(); defer { lock.unlock() }
            invocations += 1
        }

        var invocationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return invocations
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

    /// Runs the main run loop until `condition` holds or the timeout expires,
    /// and reports whether it held. Used for the IO-thread write dispatch,
    /// which is not a main-queue block and so cannot be drained through the
    /// context completion signal.
    private static func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            pumpMainRunLoopOnce()
        }
        return condition()
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
        #expect(heldSurface != nil, "the held wrapper must keep the surface alive after the view drops")

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
    /// still-alive surface invokes the write callback with the dead userdata.
    /// Pre-fix that callback retains the freed view; post-fix the context
    /// resolves nil and the response is dropped.
    ///
    /// The production callback returns before any observable side effect when
    /// `resolve()` yields nil, so its own invocation cannot be observed in the
    /// dead window. This test therefore installs a probe callback carrying the
    /// same context userdata: the probe records the invocation *before*
    /// resolving through the same `SurfaceCallbackContext` helper, which is
    /// what makes "the callback ran and dropped the response" distinguishable
    /// from "the callback never ran".
    @Test
    func writeCallbackInTheDeadViewWindowResolvesToNilWithoutCrashing() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        let collector = WriteCollector()
        var probe: WriteCallbackProbe?
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

            terminal.writeCallback = { collector.append($0) }
            terminal.setupWriteCallback()
            terminal.acceptsTerminalInput = true

            // Positive control: the same feed path delivers through the
            // production write callback while the view is alive.
            surface.feedText("\u{1B}]10;?\u{07}")
            Self.pumpMainRunLoop()
            liveDeliveryWorked = collector.combinedString.contains("\u{1B}]10;rgb:")

            // Replace the production callback with the probe, keeping the same
            // surface and the same context userdata, and let the install land
            // before the view drops. Nothing is fed between the replacement and
            // the drop, so every probe invocation below is a dead-window one.
            let installedProbe = WriteCallbackProbe(contextUserdata: surface.callbackContext.userdata)
            probe = installedProbe
            ghostty_surface_set_write_callback(
                cHandle,
                { userdata, data, len in
                    // State travels through the C userdata: a C function
                    // pointer cannot capture context, mirroring the shape of
                    // the production callback.
                    guard let probe = WriteCallbackProbe.from(userdata) else { return }
                    probe.noteInvocation()
                    guard let view = Ghostty.SurfaceCallbackContext
                        .fromOpaque(probe.contextUserdata)?
                        .resolve()
                    else {
                        probe.noteDropped()
                        return
                    }
                    probe.noteResolvedView()
                    guard let data, len > 0 else { return }
                    view.writeCallback?(Data(bytes: data, count: len))
                },
                Unmanaged.passUnretained(installedProbe).toOpaque()
            )
            Self.pumpMainRunLoop()
        }

        #expect(liveDeliveryWorked, "positive control: the write callback delivers while the view is alive")
        guard let handle, let probe else {
            Issue.record("surface creation failed")
            return
        }

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")
        #expect(heldSurface != nil, "the held wrapper must keep the surface alive after the view drops")

        let contextView = Ghostty.SurfaceCallbackContext
            .fromOpaque(ghostty_surface_userdata(handle))?
            .resolve()
        #expect(contextView == nil, "the dead view must resolve to nil")
        #expect(weakContext.value != nil, "the held surface wrapper must keep the context alive")

        // Feed with the view already gone: the probe must be invoked and must
        // resolve the dead context to nil. Pre-fix this feed crashes in the
        // freed-view retain; post-fix the response is dropped.
        let invocationsBeforeDeadFeed = probe.invocationCount
        let droppedBeforeDeadFeed = probe.droppedCount
        let resolvedViewsBeforeDeadFeed = probe.resolvedViewCount
        let deliveredBeforeDeadFeed = collector.combinedString

        let bytes = Array("\u{1B}]10;?\u{07}".utf8)
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_surface_feed_data(handle, buffer.baseAddress, buffer.count)
        }

        let observedDeadWindowInvocation = await Self.waitUntil {
            probe.invocationCount > invocationsBeforeDeadFeed
        }
        #expect(
            observedDeadWindowInvocation,
            "the dead-window write callback must actually run (a never-invoked callback must not pass)"
        )
        #expect(
            probe.droppedCount - droppedBeforeDeadFeed
                == probe.invocationCount - invocationsBeforeDeadFeed,
            "every dead-window invocation must resolve the dead view to nil and drop the response"
        )
        #expect(
            probe.resolvedViewCount == resolvedViewsBeforeDeadFeed,
            "a dead context must never resolve a view"
        )
        #expect(
            collector.combinedString == deliveredBeforeDeadFeed,
            "the dead-window response must not reach the view write callback"
        )

        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
    }

    // MARK: - #312 clipboard / close / free coverage

    /// Live-path acceptance for `Ghostty.App.readClipboard` (#312): a real
    /// custom-IO surface with a readable clipboard must paste the payload
    /// through the write callback.
    ///
    /// `pasteTextFromClipboard()` drives this same binding but discards its
    /// `Bool`, and #312 wants the binding's answer, so the test calls
    /// `perform(action:)` directly; `acceptsTerminalInput = true` states the
    /// view-level precondition (`canRouteTerminalInput`) explicitly.
    ///
    /// The payload is single-line on purpose: a multi-line payload fails
    /// `input.paste.isSafe` and dead-ends in the confirm stub (#327), which is
    /// deliberately not exercised here.
    @Test
    func readClipboardResolvesTheLiveViewAndPastesTheClipboard() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "clipboard-live")
        defer { terminal.cleanup() }

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)
        #expect(surface.callbackContext.resolve() === terminal, "positive control: the context must resolve the live view")

        let collector = WriteCollector()
        terminal.writeCallback = { collector.append($0) }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        let payload = "vvterm-#312-live-\(UUID().uuidString)"
        Clipboard.copy(payload)
        #expect(Clipboard.readString() == payload, "the clipboard seed must read back before the paste")
        #expect(collector.combinedString.isEmpty, "positive control: the collector must be empty before the paste")

        let handled = surface.perform(action: "paste_from_clipboard")
        #expect(handled, "the live paste binding must report true")

        // The paste write is queued through the custom-IO FIFO to the termio
        // thread, so bounded-wait for the delivery instead of pumping a fixed
        // number of turns.
        let delivered = await Self.waitUntil(timeout: 5.0) {
            collector.combinedString.contains(payload)
        }
        #expect(delivered, "the pasted clipboard payload must reach the write callback")
    }

    /// Dead-window acceptance for `Ghostty.App.readClipboard` (#312): the view
    /// is gone but the surface wrapper (and therefore the context userdata) is
    /// retained, so the paste binding drives the real clipboard route. The
    /// route must report `false` and write nothing.
    ///
    /// The clipboard is seeded non-empty first: otherwise `false` could just
    /// mean "empty clipboard" and the suppression claim would be vacuous.
    @Test
    func readClipboardReturnsFalseAndWritesNothingInTheDeadViewWindow() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        let collector = WriteCollector()
        var heldSurface: Ghostty.Surface?
        var handle: ghostty_surface_t?
        var userdataIsContext = false

        let payload = "vvterm-#312-dead-\(UUID().uuidString)"
        Clipboard.copy(payload)
        #expect(Clipboard.readString() == payload, "the clipboard must be seeded before the dead-window paste")

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "clipboard-dead-window")
            weakView.value = terminal
            guard let surface = terminal.surface, let cHandle = surface.unsafeCValue else { return }
            heldSurface = surface
            handle = cHandle
            weakContext.value = surface.callbackContext

            terminal.writeCallback = { collector.append($0) }
            terminal.setupWriteCallback()
            terminal.acceptsTerminalInput = true

            userdataIsContext = ghostty_surface_userdata(cHandle) == surface.callbackContext.userdata
        }

        #expect(userdataIsContext, "the surface userdata must be the retained context before the view drops")
        guard let handle, heldSurface != nil else {
            Issue.record("surface creation failed")
            return
        }

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")
        #expect(heldSurface != nil, "the held wrapper must keep the surface alive after the view drops")
        #expect(weakContext.value != nil, "the held wrapper must keep the context alive after the view drops")

        let userdata = ghostty_surface_userdata(handle)
        #expect(userdata != nil, "the surface must still carry the context userdata")
        let deadContextView = Ghostty.SurfaceCallbackContext.fromOpaque(userdata)?.resolve()
        #expect(deadContextView == nil, "the dead view must resolve to nil")

        let handled = heldSurface?.perform(action: "paste_from_clipboard")
        #expect(handled == false, "the dead-window paste binding must report false")

        let wrote = await Self.waitUntil(timeout: 0.5) { !collector.combinedString.isEmpty }
        #expect(wrote == false, "the dead-window paste must not write anything to the terminal")

        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
    }

    /// Live-path acceptance for `Ghostty.App.closeSurface` (#312): the close
    /// callback resolves the live view and dispatches `onProcessExit`.
    ///
    /// The dispatch is a main-queue block, which a bare run-loop pump does not
    /// run (measured by this suite), so the test bounded-waits on the spy.
    @Test
    func closeSurfaceInvokesOnProcessExitWhileTheViewIsAlive() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "close-live")
        defer { terminal.cleanup() }

        let surface = try #require(terminal.surface)
        let handle = try #require(surface.unsafeCValue)
        #expect(surface.callbackContext.resolve() === terminal, "positive control: the context must resolve the live view")

        let spy = InvocationSpy()
        terminal.onProcessExit = { spy.noteInvocation() }

        // Pass the userdata the way the core's `close_surface_cb` would: the
        // surface's own userdata, not the context pointer (identical post-#310).
        let userdata = try #require(ghostty_surface_userdata(handle))
        Ghostty.App.closeSurface(userdata, processAlive: false)

        let dispatched = await Self.waitUntil { spy.invocationCount > 0 }
        #expect(dispatched, "closeSurface must dispatch onProcessExit on the main queue while the view is alive")
    }

    /// Dead-window acceptance for `Ghostty.App.closeSurface` (#312): the dead
    /// userdata must resolve to nil, so the call neither crashes nor dispatches
    /// to a live control view's `onProcessExit`.
    @Test
    func closeSurfaceInTheDeadViewWindowDoesNotCrashOrDispatch() async throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)

        // Live control: its spy must stay silent when the call carries the dead
        // userdata instead.
        let controlTerminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "close-live-control")
        defer { controlTerminal.cleanup() }
        let controlSurface = try #require(controlTerminal.surface)
        _ = try #require(controlSurface.unsafeCValue)
        #expect(
            controlSurface.callbackContext.resolve() === controlTerminal,
            "positive control: the control context must resolve its live view"
        )
        let controlSpy = InvocationSpy()
        controlTerminal.onProcessExit = { controlSpy.noteInvocation() }

        let weakView = WeakBox<GhosttyTerminalView>()
        let weakContext = WeakBox<Ghostty.SurfaceCallbackContext>()
        var heldSurface: Ghostty.Surface?
        var handle: ghostty_surface_t?
        var userdataIsContext = false

        autoreleasepool {
            let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "close-dead-window")
            weakView.value = terminal
            guard let surface = terminal.surface, let cHandle = surface.unsafeCValue else { return }
            heldSurface = surface
            handle = cHandle
            weakContext.value = surface.callbackContext
            userdataIsContext = ghostty_surface_userdata(cHandle) == surface.callbackContext.userdata
        }

        #expect(userdataIsContext, "the surface userdata must be the retained context before the view drops")
        guard let handle, heldSurface != nil else {
            Issue.record("surface creation failed")
            return
        }

        await Self.waitUntilViewDeallocates(weakView)
        #expect(weakView.value == nil, "the view must deallocate once its last reference drops")
        #expect(heldSurface != nil, "the held wrapper must keep the surface alive after the view drops")
        #expect(weakContext.value != nil, "the held wrapper must keep the context alive after the view drops")

        let userdata = ghostty_surface_userdata(handle)
        #expect(userdata != nil, "the surface must still carry the context userdata")
        let deadContextView = Ghostty.SurfaceCallbackContext.fromOpaque(userdata)?.resolve()
        #expect(deadContextView == nil, "the dead view must resolve to nil")

        Ghostty.App.closeSurface(userdata, processAlive: false)

        let dispatched = await Self.waitUntil(timeout: 0.5) { controlSpy.invocationCount > 0 }
        #expect(dispatched == false, "the dead-window close must not dispatch the control view's onProcessExit")

        heldSurface = nil
        #expect(weakContext.value != nil, "the queued deferred free block must retain the context")
        let drained = await Self.drainUntilNil(weakContext)
        #expect(drained, "the deferred free block must run and release the context")
    }

    /// `Ghostty.Surface.free()`'s invalidate (#312): drive the production
    /// teardown (`terminal.cleanup()` runs `LayerTeardown.prepare` then
    /// `free()`) while retaining the view, and assert the context is already
    /// invalidated — suppression from invalidation, not from the weak view
    /// going nil.
    ///
    /// The direct `readClipboard` probe runs against a non-empty clipboard so
    /// its `false` cannot be the empty-clipboard `false`. No deferred-free
    /// drain here: `cleanup()` frees synchronously.
    @Test
    func freeInvalidatesTheContextWhileTheViewIsStillAlive() throws {
        let app = Ghostty.App()
        defer { app.cleanup() }
        let appHandle = try #require(app.app)
        let terminal = Self.makeTerminal(app: app, appHandle: appHandle, paneId: "free-invalidate")

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)
        let context = surface.callbackContext
        weak var weakView: GhosttyTerminalView? = terminal
        #expect(context.resolve() === terminal, "positive control: the context must resolve the live view before cleanup")

        let payload = "vvterm-#312-free-\(UUID().uuidString)"
        Clipboard.copy(payload)
        #expect(Clipboard.readString() == payload, "the clipboard must be non-empty before the suppression probe")

        terminal.cleanup()

        // Swift may end a local's lifetime at its last use; the post-cleanup
        // assertions need the view demonstrably alive while the context is
        // already invalidated.
        withExtendedLifetime(terminal) {
            #expect(weakView != nil, "cleanup() must not deallocate the retained view")
            #expect(context.resolve() == nil, "free() must invalidate the context while the view is still alive")

            let handled = Ghostty.App.readClipboard(
                context.userdata,
                location: GHOSTTY_CLIPBOARD_STANDARD,
                state: nil
            )
            #expect(
                handled == false,
                "an invalidated context must refuse the clipboard read even with a non-empty clipboard"
            )
        }
    }
}
