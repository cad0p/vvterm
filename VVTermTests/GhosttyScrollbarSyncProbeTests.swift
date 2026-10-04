import Foundation
import CoreGraphics
import os
import Testing
@testable import VVTerm

/// Documents the delivery contract of ghostty's scrollbar action
/// notification (`Ghostty.Action.ghosttyDidUpdateScrollbar`).
///
/// Full-screen zen overscroll edge detection reads `terminal.scrollbar`
/// during pan handling and re-applies the one-shot initial reveal from the
/// scrollbar observer. The delivery mode decides how fresh the edge state
/// is: synchronous delivery would mean `sendMouseScroll` updates the
/// scrollbar state before the call returns; asynchronous delivery means the
/// edge state lags the gesture and the UI must not assume in-call
/// freshness.
///
/// Probe result (CI, 2026-08): the notification does NOT fire synchronously
/// inside `sendMouseScroll`. The ghostty callback posts from its own
/// thread, so the scrollbar state observed during a pan is the last-known
/// state from a previous runloop turn. The overscroll rules already treat
/// the scrollbar as best-effort (loops of small deltas converge), and the
/// UI tests drive repeated swipe loops for that reason.
@Suite(.serialized)
@MainActor
struct GhosttyScrollbarSyncProbeTests {
    @Test
    func scrollbarNotificationIsNeverDeliveredSynchronouslyInsideSendMouseScroll() async throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "scrollbar-sync-probe",
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface)
        let rowCount = max(Int(surface.terminalSize()?.rows ?? 24), 4)
        // The observer block runs on the notification's posting thread while
        // the test polls on MainActor, so the delivery state is read and
        // written through a lock.
        let deliveryState = ScrollbarDeliveryState()
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminal,
            queue: nil
        ) { _ in
            // This block runs on the posting thread (queue: nil).
            deliveryState.record(isMainThread: Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Feed enough output that a scrollback exists (rows + 6 extra lines).
        // The growth posts scrollbar updates asynchronously; wait for that
        // notification stream to settle (bounded, observing the notifications
        // directly) instead of sleeping a fixed settle, then reset so the
        // probe below classifies deliveries that follow the feed.
        let lines = (0..<(rowCount + 6)).map { "vvterm-scroll-probe-\($0)" }
        surface.feedText(lines.joined(separator: "\r\n") + "\r\n")
        #expect(
            await waitForScrollbarSettle { deliveryState.deliveries },
            "the feed must post its scrollbar updates before the scroll probe"
        )
        deliveryState.resetThreadFlags()

        // Scroll up (negative y = toward older content on macOS coordinates).
        surface.sendMouseScroll(
            Ghostty.Input.MouseScrollEvent(
                x: 0,
                y: Double(-rowCount * 20),
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
        )
        // The observer uses `queue: nil`, so a synchronous delivery would have
        // run on this (main) thread before `sendMouseScroll` returned. Capture
        // the in-call window immediately.
        let deliveredSynchronouslyOnMain = deliveryState.deliveredOnMain

        // The core does not promise an immediate scrollbar flush; poll a few
        // runloop turns for the eventual delivery and record its thread.
        for _ in 0..<20 where !deliveryState.deliveredOnMain && !deliveryState.deliveredOnBackground {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(
            !deliveredSynchronouslyOnMain,
            "scrollbar notification must not be delivered synchronously on the calling thread inside sendMouseScroll — the edge state may legitimately lag by a runloop turn"
        )
        // When the update does arrive it comes from the ghostty callback
        // thread, never synchronously on the calling (main) thread.
        if deliveryState.deliveredOnMain || deliveryState.deliveredOnBackground {
            #expect(
                deliveryState.deliveredOnBackground,
                "scrollbar notification must be posted from the ghostty callback thread (main-thread delivery observed: \(deliveryState.deliveredOnMain))"
            )
        }
    }

    /// Bounded wait for the feed's scrollbar notifications to settle: at
    /// least one delivery observed, then no new delivery for a quiet window.
    /// The old code slept 300 ms for this; this observes the notification
    /// stream directly.
    private func waitForScrollbarSettle(
        deliveries: @escaping () -> Int,
        timeout: Duration = .seconds(2),
        quietWindow: Duration = .milliseconds(200)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var observed = 0
        var lastChange = clock.now
        while clock.now < deadline {
            let current = deliveries()
            if current != observed {
                observed = current
                lastChange = clock.now
            } else if observed > 0, lastChange.duration(to: clock.now) >= quietWindow {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

/// Delivery observations shared between the `queue: nil` observer block (which
/// runs on the notification's posting thread) and the MainActor test. A lock
/// keeps the cross-thread reads and writes race-free.
private final class ScrollbarDeliveryState {
    private struct State {
        var deliveries = 0
        var deliveredOnMain = false
        var deliveredOnBackground = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func record(isMainThread: Bool) {
        lock.withLock { state in
            state.deliveries += 1
            if isMainThread {
                state.deliveredOnMain = true
            } else {
                state.deliveredOnBackground = true
            }
        }
    }

    func resetThreadFlags() {
        lock.withLock { state in
            state.deliveredOnMain = false
            state.deliveredOnBackground = false
        }
    }

    var deliveries: Int { lock.withLock { $0.deliveries } }
    var deliveredOnMain: Bool { lock.withLock { $0.deliveredOnMain } }
    var deliveredOnBackground: Bool { lock.withLock { $0.deliveredOnBackground } }
}
