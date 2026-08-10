import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

/// Probes whether ghostty's scrollbar action notification is delivered
/// synchronously on the calling (main) thread inside `sendMouseScroll`.
/// Full-screen zen overscroll edge detection reads `terminal.scrollbar`
/// during pan handling; if the notification is asynchronous, the edge state
/// lags the gesture by a runloop turn and deltas can be misclassified.
@Suite(.serialized)
@MainActor
struct GhosttyScrollbarSyncProbeTests {
    @Test
    func scrollbarNotificationIsSynchronousOnMainThread() async throws {
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
        let cSurface = try #require(surface.unsafeCValue)
        let rowCount = max(Int(surface.terminalSize()?.rows ?? 24), 4)
        // Feed enough output that a scrollback exists (rows + 6 extra lines).
        let lines = (0..<(rowCount + 6)).map { "vvterm-scroll-probe-\($0)" }
        surface.feedText(lines.joined(separator: "\r\n") + "\r\n")

        // Let the core settle (scrollback growth posts scrollbar updates).
        try await Task.sleep(for: .milliseconds(300))

        var deliveredSynchronously = false
        var deliveredOnBackground = false
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: terminal,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                deliveredSynchronously = true
            } else {
                deliveredOnBackground = true
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Scroll up (negative y = toward older content on macOS coordinates).
        surface.sendMouseScroll(
            Ghostty.Input.MouseScrollEvent(
                x: 0,
                y: Double(-rowCount * 20),
                mods: Ghostty.Input.ScrollMods(precision: true, momentum: .none)
            )
        )

        // Immediately after the call returns: did the callback already fire?
        if !deliveredSynchronously && !deliveredOnBackground {
            // Give an async delivery one runloop turn before declaring.
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(
            deliveredSynchronously,
            "scrollbar notification should be delivered synchronously on the calling thread (background delivery observed: \(deliveredOnBackground))"
        )
    }
}
