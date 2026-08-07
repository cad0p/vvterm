import Foundation
import CoreGraphics
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
    func openURLHTTPActionIsHandledAndRouted() {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        defer { Ghostty.App.externalURLHandler = original }

        let handled = callOpenURLHandler(urlString: "https://example.com/path?q=1#frag")

        #expect(handled)
        pumpMainQueue()
        #expect(sink.urls == [URL(string: "https://example.com/path?q=1#frag")])
    }

    @Test
    func openURLHTTPSActionIsHandledAndRouted() {
        let sink = URLSink()
        let original = Ghostty.App.externalURLHandler
        Ghostty.App.externalURLHandler = { sink.append($0) }
        defer { Ghostty.App.externalURLHandler = original }

        let handled = callOpenURLHandler(urlString: "http://example.com")

        #expect(handled)
        pumpMainQueue()
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
    func tapOnOSC8LinkInRealSurfaceOpensURL() throws {
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
        Ghostty.App.externalURLHandler = { sink.append($0) }
        defer { Ghostty.App.externalURLHandler = original }

        // A real layout would set the size; do it explicitly so the grid and
        // cell metrics are well-defined regardless of renderer state.
        ghostty_surface_set_size(surfaceC, 800, 600)

        // OSC 8 hyperlink: ESC ]8;;URL ESC \ label ESC ]8;; ESC \
        surface.feedText("\u{1B}]8;;https://example.com\u{1B}\\VVTERM-OSC8-LINK\u{1B}]8;;\u{1B}\\\n")
        pumpMainQueue()

        // Tap the center of the link's cell (0,0) using the core's own cell
        // metrics — the same numbers the core uses for pixel→cell conversion.
        let metrics = ghostty_surface_size(surfaceC)
        #expect(metrics.cell_width_px > 0, "core must report a real cell width (font metrics loaded)")
        #expect(metrics.cell_height_px > 0, "core must report a real cell height (font metrics loaded)")

        let tap = CGPoint(x: Double(metrics.cell_width_px) / 2, y: Double(metrics.cell_height_px) / 2)
        surface.sendMousePos(.init(x: tap.x, y: tap.y, mods: []))
        _ = surface.sendMouseButton(.init(action: .press, button: .left, mods: []))
        _ = surface.sendMouseButton(.init(action: .release, button: .left, mods: []))
        pumpMainQueue()

        #expect(sink.urls == [URL(string: "https://example.com")])
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

    private func pumpMainQueue() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
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
