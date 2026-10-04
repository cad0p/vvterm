import Foundation
import CoreGraphics
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
        var deliveries = 0
        var deliveredOnMain = false
        var deliveredOnBackground = false
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminal,
            queue: nil
        ) { _ in
            // This block runs on the posting thread (queue: nil).
            deliveries += 1
            if Thread.isMainThread {
                deliveredOnMain = true
            } else {
                deliveredOnBackground = true
            }
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
            await waitForScrollbarSettle { deliveries },
            "the feed must post its scrollbar updates before the scroll probe"
        )
        deliveredOnMain = false
        deliveredOnBackground = false

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
        let deliveredSynchronouslyOnMain = deliveredOnMain

        // The core does not promise an immediate scrollbar flush; poll a few
        // runloop turns for the eventual delivery and record its thread.
        for _ in 0..<20 where !deliveredOnMain && !deliveredOnBackground {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(
            !deliveredSynchronouslyOnMain,
            "scrollbar notification must not be delivered synchronously on the calling thread inside sendMouseScroll — the edge state may legitimately lag by a runloop turn"
        )
        // When the update does arrive it comes from the ghostty callback
        // thread, never synchronously on the calling (main) thread.
        if deliveredOnMain || deliveredOnBackground {
            #expect(
                deliveredOnBackground,
                "scrollbar notification must be posted from the ghostty callback thread (main-thread delivery observed: \(deliveredOnMain))"
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
