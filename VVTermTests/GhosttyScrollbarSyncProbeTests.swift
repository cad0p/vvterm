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
        // Feed enough output that a scrollback exists (rows + 6 extra lines).
        let lines = (0..<(rowCount + 6)).map { "vvterm-scroll-probe-\($0)" }
        surface.feedText(lines.joined(separator: "\r\n") + "\r\n")

        // Let the core settle (scrollback growth posts scrollbar updates).
        try await Task.sleep(for: .milliseconds(300))

        var deliveredInsideCall = false
        var deliveredOnMain = false
        var deliveredOnBackground = false
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminal,
            queue: nil
        ) { _ in
            // This block runs on the posting thread (queue: nil).
            if Thread.isMainThread {
                deliveredOnMain = true
            } else {
                deliveredOnBackground = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Scroll up (negative y = toward older content on macOS coordinates).
        var inCall = true
        surface.sendMouseScroll(
            Ghostty.Input.MouseScrollEvent(
                x: 0,
                y: Double(-rowCount * 20),
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
        )
        inCall = false
        deliveredInsideCall = deliveredOnMain || deliveredOnBackground

        // The core does not promise an immediate scrollbar flush; poll a few
        // runloop turns for the eventual delivery and record its thread.
        for _ in 0..<20 where !deliveredOnMain && !deliveredOnBackground {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(
            !deliveredInsideCall,
            "scrollbar notification must not be delivered synchronously inside sendMouseScroll — the edge state may legitimately lag by a runloop turn"
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
}
