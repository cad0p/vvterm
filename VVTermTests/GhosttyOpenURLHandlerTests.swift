import Foundation
import CoreGraphics
import UIKit
import Testing
@testable import VVTerm

/// Verifies the apprt handles `GHOSTTY_ACTION_OPEN_URL` — the action the
/// ghostty core emits when an OSC 8 hyperlink (or file/text link) under the
/// pointer is activated by a left-click release.
///
/// Regression: the action had no case in `Ghostty.App.action`, so it fell to
/// `default` (return false) and the core fell back to its own opener
/// (`internal_os.open`), which is `error.Unimplemented` on iOS — OSC 8
/// inline links in real SSH sessions were not clickable at all.
@Suite(.serialized)
@MainActor
struct GhosttyOpenURLHandlerTests {

    // MARK: - Direct handler tests

    @Test
    func openURLHTTPActionIsHandledAndRouted() async {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        let originalConfirmation = Ghostty.App.linkConfirmationHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        Ghostty.App.linkConfirmationHandler = { _, done in done(true) }
        defer {
            Ghostty.App.externalURLHandler = original
            Ghostty.App.linkConfirmationHandler = originalConfirmation
        }

        let handled = callOpenURLHandler(urlString: "https://example.com/path?q=1#frag")

        #expect(handled)
        await waitForSink(sink)
        #expect(sink.urls == [URL(string: "https://example.com/path?q=1#frag")])
    }

    @Test
    func openURLHTTPSActionIsHandledAndRouted() async {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        let originalConfirmation = Ghostty.App.linkConfirmationHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        Ghostty.App.linkConfirmationHandler = { _, done in done(true) }
        defer {
            Ghostty.App.externalURLHandler = original
            Ghostty.App.linkConfirmationHandler = originalConfirmation
        }

        let handled = callOpenURLHandler(urlString: "http://example.com")

        #expect(handled)
        await waitForSink(sink)
        #expect(sink.urls == [URL(string: "http://example.com")])
    }

    @Test
    func openURLNonHTTPSchemeIsNotHandled() {
        // A remote host controls this string; file:// and other schemes must
        // not be routed to the platform opener. Return false → the core's
        // fallback handles it (macOS `open` for file://, iOS no-op).
        let handled = callOpenURLHandler(urlString: "file:///etc/passwd")
        #expect(!handled)
    }

    @Test
    func openURLMalformedOrEmptyIsNotHandled() {
        #expect(!callOpenURLHandler(urlString: ""))
        #expect(!callOpenURLHandler(urlString: "not a url"))
        #expect(!callOpenURLHandler(urlString: "javascript:alert(1)"))
    }

    // MARK: - In-process reproduction: real surface + synthetic tap

    /// Full click-path reproduction: a real custom-I/O surface, an OSC 8
    /// link fed as terminal input, a synthetic left-click tap on the link's
    /// cell — the core must emit `open_url` and the apprt must route it.
    @Test
    func tapOnOSC8LinkInRealSurfaceOpensURL() async throws {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "osc8-link-tap",
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }
        let surface = try #require(terminal.surface)
        let surfaceC = try #require(surface.unsafeCValue)
        // Mirror the known-good custom-I/O harness setup from
        // GhosttyOSCColorQueryTests.
        terminal.writeCallback = { _ in }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        let originalConfirmation = Ghostty.App.linkConfirmationHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        Ghostty.App.linkConfirmationHandler = { _, done in done(true) }
        defer {
            Ghostty.App.externalURLHandler = original
            Ghostty.App.linkConfirmationHandler = originalConfirmation
        }

        // A real layout would set the size; do it explicitly so the grid and
        // cell metrics are well-defined regardless of renderer state.
        ghostty_surface_set_size(surfaceC, 800, 600)

        // OSC 8 hyperlink: ESC ]8;;URL ESC \ label ESC ]8;; ESC \
        surface.feedText("\u{1B}]8;;https://example.com\u{1B}\\VVTERM-OSC8-LINK\u{1B}]8;;\u{1B}\\\n")
        // The parser is sequential and feed→read is synchronous, so reading
        // the label back at the tap cell proves the OSC 8 open sequence has
        // been consumed before the synthetic tap can miss it.
        #expect(
            await waitForCellText(
                surfaceC,
                row: 0,
                column: 0,
                containing: "VVTERM-OSC8-LINK"
            ),
            "the OSC 8 label must be parsed into the grid before the tap"
        )

        // Tap the center of the link's cell (0,0). The core's mouse events
        // are in POINTS (the app sends recognizer points), but
        // ghostty_surface_size reports cell metrics in PIXELS — convert via
        // the view's content scale (3x in the simulator). Sending the pixel
        // value directly overshoots by the scale factor and lands on a
        // different row, missing the link.
        //
        // The core only activates OSC 8 hyperlinks when the click mods equal
        // ctrlOrSuper(.{}) (super on Darwin) — a plain tap is never a link
        // click. Super is not encoded in terminal mouse reports.
        let metrics = ghostty_surface_size(surfaceC)
        #expect(metrics.cell_width_px > 0, "core must report a real cell width (font metrics loaded)")
        #expect(metrics.cell_height_px > 0, "core must report a real cell height (font metrics loaded)")
        let scale = max(terminal.contentScaleFactor, 1)
        let tap = CGPoint(
            x: Double(metrics.cell_width_px) / scale / 2,
            y: Double(metrics.cell_height_px) / scale / 2
        )
        let linkTapMods: Ghostty.Input.Mods = [.super]
        surface.sendMousePos(.init(x: tap.x, y: tap.y, mods: linkTapMods))
        _ = surface.sendMouseButton(.init(action: .press, button: .left, mods: linkTapMods))
        _ = surface.sendMouseButton(.init(action: .release, button: .left, mods: linkTapMods))
        await waitForSink(sink)

        #expect(sink.urls == [URL(string: "https://example.com")])
    }

    // MARK: - Link confirmation

    @Test
    func openURLConfirmationCancelSuppressesOpen() async {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        let originalConfirmation = Ghostty.App.linkConfirmationHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        Ghostty.App.linkConfirmationHandler = { _, done in done(false) }
        defer {
            Ghostty.App.externalURLHandler = original
            Ghostty.App.linkConfirmationHandler = originalConfirmation
        }

        let handled = callOpenURLHandler(urlString: "https://example.com/path?q=1#frag")

        #expect(handled)
        // Let the async hops (open_url dispatch → confirmation → opener)
        // settle; the opener must never run after a cancel.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(sink.urls.isEmpty)
    }

    @Test
    func openURLConfirmationReceivesExactURL() async {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        let originalConfirmation = Ghostty.App.linkConfirmationHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        var confirmedURL: URL?
        Ghostty.App.linkConfirmationHandler = { url, done in
            confirmedURL = url
            done(true)
        }
        defer {
            Ghostty.App.externalURLHandler = original
            Ghostty.App.linkConfirmationHandler = originalConfirmation
        }

        let handled = callOpenURLHandler(urlString: "https://example.com/path?q=1#frag")

        #expect(handled)
        await waitForSink(sink)
        #expect(confirmedURL == URL(string: "https://example.com/path?q=1#frag"))
        #expect(sink.urls == [URL(string: "https://example.com/path?q=1#frag")])
    }

    // MARK: - Helpers

    /// Builds a `GHOSTTY_ACTION_OPEN_URL` action with the given URL string
    /// and drives the app's C callback directly (target = app, so no surface
    /// is dereferenced).
    @discardableResult
    private func callOpenURLHandler(urlString: String) -> Bool {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP

        // The imported C struct has no memberwise init; fill fields directly.
        // CChar(bitPattern:) preserves the UTF-8 bytes for the C string.
        let cchars = urlString.utf8.map { CChar(bitPattern: $0) }
        return cchars.withUnsafeBufferPointer { buffer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            var openURL = ghostty_action_open_url_s()
            openURL.kind = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
            openURL.url = buffer.baseAddress
            openURL.len = UInt(cchars.count)
            action.action.open_url = openURL
            // ghostty_app_t is a non-optional raw pointer; the handler only
            // dereferences it for surface targets, so a dummy pointer is
            // safe for the .app-target path exercised here.
            return Ghostty.App.action(
                UnsafeMutableRawPointer(bitPattern: 0x1)!,
                target: target,
                action: action
            )
        }
    }

    /// Bounded read-back of the grid cells starting at `(row, column)`.
    /// Returns `false` on timeout so the caller's `#expect` is the gate; the
    /// poll interval is bounded by the deadline.
    private func waitForCellText(
        _ surface: ghostty_surface_t,
        row: UInt32,
        column: UInt32,
        containing needle: String,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if cellText(surface, row: row, column: column, width: needle.count)
                .contains(needle) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Reads `width` cells from `(row, column)` via
    /// `ghostty_surface_read_text`, always freeing the core-owned
    /// `ghostty_text_s` and decoding its UTF-8 bytes with a test-local
    /// converter (`ghosttyTextString` is private to the view).
    private func cellText(
        _ surface: ghostty_surface_t,
        row: UInt32,
        column: UInt32,
        width: Int
    ) -> String {
        let span = UInt32(max(width, 1))
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: column,
                y: row
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: column + span - 1,
                y: row
            ),
            rectangle: true
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let rawText = text.text else { return "" }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(rawText).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The handler routes through `DispatchQueue.main.async`, so the test
    /// must yield the main actor for the block to run — a run-loop pump is
    /// not enough on the swift-testing executor. Bounded wait on the sink.
    private func waitForSink(_ sink: URLSink, count: Int = 1, timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sink.urls.count < count {
            if clock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Collects URLs the app would hand to the platform opener. Written from
/// the main queue (via the handler's async dispatch) and read by the test.
private final class URLSink {
    private let lock = NSLock()
    private var stored: [URL] = []

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        stored.append(url)
    }
}
