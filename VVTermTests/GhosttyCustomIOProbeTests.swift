import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

/// Probe tests for the ghostty custom-I/O termio backend carried by
/// `scripts/patches/ghostty/custom-io.patch` (issue #127 / ADR
/// `2026-08-11-ghostty-upstream-patchqueue-weekly-probe`). These tests prove
/// the vendored xcframework engages its `use_custom_io` path at runtime, and
/// pin the no-pty contract the SSH integration relies on.
///
/// WHY THE WRITE-CALLBACK ROUND-TRIP IS THE PRIMARY ASSERTION
/// ----------------------------------------------------------
/// The distinguishing behavioral check is
/// `customIOWriteCallbackRoundTripDeliversOSCResponse`: feed an OSC 10 color
/// query and assert the reply arrives through the Swift write callback. If the
/// `use_custom_io` config write were inert — i.e. the surface silently fell
/// back to the pty/Exec backend — the terminal would write the OSC response
/// into the PTY master, where it is consumed by the child process's line
/// discipline and never reaches the callback. The collector stays empty and
/// the test fails. In other words, a non-engaged custom-I/O config is caught
/// behaviorally, which is exactly the "config struct offset write" bug class
/// this probe exists to detect.
///
/// A companion pre-feed assertion ("collector is empty before any input") pins
/// the zero-spontaneous-writes property: in custom-io mode nothing is written
/// until the terminal reacts to input, so bytes appearing before the feed
/// would also indicate the wrong backend.
///
/// WHY THERE IS NO dlsym / SYMBOL-PRESENCE CHECK
/// ---------------------------------------------
/// The four fork symbols (`use_custom_io` config field,
/// `ghostty_surface_write_fn`, `ghostty_surface_feed_data`,
/// `ghostty_surface_set_write_callback`) are enforced at link time by the
/// Swift call sites in `GhosttyTerminalView`/`Ghostty.Surface` and at compile
/// time by the C struct fields in the vendored `include/ghostty.h`. The app
/// cannot build without them, so a runtime symbol probe would only duplicate
/// the build system's work — the symbols resolve statically into the app
/// binary.
///
/// Byte assertions are intentionally coarse: ghostty may normalize newlines
/// or batch/fragment callback invocations, so the tests assert presence
/// (non-empty stream, substring match, OSC response shape) rather than exact
/// byte equality.
///
/// These tests run in PR CI's unit-tests job on the iOS Simulator
/// (`-scheme VVTermUnitTests -destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64'`)
/// and in the weekly ghostty-upstream-probe workflow. They mirror the
/// structure of `GhosttyOSCColorQueryTests` (real `GhosttyTerminalView` with
/// `useCustomIO: true`, write callback + `setupWriteCallback()`, `feedText`,
/// runloop pump).
@Suite(.serialized)
@MainActor
struct GhosttyCustomIOProbeTests {

    /// THE primary distinguishing assertion for the custom-I/O backend.
    ///
    /// With `useCustomIO: true` the write callback must deliver the terminal's
    /// output. In pty mode the OSC response would be written into the PTY
    /// master / line discipline instead, the collector stays empty, and this
    /// test fails — so an inert `use_custom_io` config write is caught
    /// behaviorally (see the file header for the full rationale).
    @Test
    func customIOWriteCallbackRoundTripDeliversOSCResponse() throws {
        let harness = try makeProbeHarness(paneId: "custom-io-probe-osc")
        defer { harness.cleanup() }

        // Zero spontaneous writes: in custom-io mode nothing is emitted until
        // the terminal reacts to input. Asserted before any feed, so a stray
        // write would also flag a wrong backend.
        #expect(harness.collector.combinedString().isEmpty)

        // OSC 10 color query: ESC ] 10 ; ? ST
        harness.surface.feedText("\u{1B}]10;?\u{07}")
        pumpRunloop()

        let response = try #require(firstOSCResponse(in: harness.collector.combinedString(), index: "10"))
        #expect(response.hasPrefix("\u{1B}]10;rgb:"))
    }

    /// Keyboard → host direction (the SSH input path).
    ///
    /// `sendText` on `Ghostty.Surface` maps to `ghostty_surface_text` — it
    /// feeds raw text, not key events, so no key-event encoding applies. In
    /// custom-io mode the terminal's output path is the write callback, which
    /// must therefore receive the text. Keep the byte assertion coarse: ghostty
    /// may normalize newlines, so require the callback fired with non-empty
    /// data containing "probe", not exact byte equality.
    @Test
    func customIOKeyboardInputReachesWriteCallback() throws {
        let harness = try makeProbeHarness(paneId: "custom-io-probe-keyboard")
        defer { harness.cleanup() }

        harness.surface.sendText("probe\r")
        pumpRunloop()

        let stream = harness.collector.combinedString()
        #expect(!stream.isEmpty)
        #expect(stream.contains("probe"))
    }

    /// No-pty contract: custom-io surfaces spawn no child process, so
    /// `ghostty_surface_process_exited` (which reads `core_surface.child_exited`)
    /// stays false even after a feed round-trip and several runloop turns.
    @Test
    func customIOProcessExitedStaysFalse() throws {
        let harness = try makeProbeHarness(paneId: "custom-io-probe-exit")
        defer { harness.cleanup() }

        #expect(harness.terminal.processExited == false)

        // Exercise the same round-trip as the primary test, checking the
        // process-exited flag stays false across every runloop turn.
        harness.surface.feedText("\u{1B}]10;?\u{07}")

        for _ in 0..<10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            #expect(harness.terminal.processExited == false)
        }

        #expect(harness.terminal.processExited == false)
        #expect(!harness.collector.combinedString().isEmpty)
    }

    // MARK: - Helpers

    /// Creates a real `GhosttyTerminalView` in custom-I/O mode, installs the
    /// write callback + `setupWriteCallback()`, and returns a harness with the
    /// live surface and collector so the test can drive the round-trip and
    /// assert mid-flight state. Cleanup (view + app) runs via `harness.cleanup()`.
    private func makeProbeHarness(paneId: String) throws -> ProbeHarness {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: paneId,
            useCustomIO: true
        )

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)

        let collector = WriteCollector()
        terminal.writeCallback = { data in
            collector.append(data)
        }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        return ProbeHarness(
            terminal: terminal,
            surface: surface,
            collector: collector,
            cleanup: {
                terminal.cleanup()
                app.cleanup()
            }
        )
    }

    /// Pumps the run loop a few times to flush any deferred dispatch used by
    /// the redraw scheduler. libghostty emits OSC responses synchronously
    /// during feed_data on the custom-I/O path, so the pumps are a flush, not
    /// the delivery mechanism.
    private func pumpRunloop() {
        for _ in 0..<10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Scans the captured host stream for the first complete OSC response of
    /// the form `ESC ] <index> ; rgb:... ST`. Returns the substring spanning
    /// from the introducer to the terminator (inclusive), or nil if absent.
    /// Mirrors `GhosttyOSCColorQueryTests.firstOSCResponse`.
    private func firstOSCResponse(in stream: String, index: String) -> String? {
        let introducer = "\u{1B}]\(index);"
        guard let introducerRange = stream.range(of: introducer) else { return nil }
        let after = stream[introducerRange.upperBound...]
        // The response payload must start with rgb: for a color query reply.
        guard after.hasPrefix("rgb:") else { return nil }
        // Find the terminator: BEL (0x07) or ESC \ (0x1b 0x5c).
        let bel = after.firstIndex(of: "\u{07}")
        let st = after.range(of: "\u{1B}\\")?.lowerBound
        let end: String.Index
        switch (bel, st) {
        case let (b?, s?):
            end = min(b, s)
        case (let b?, nil):
            end = b
        case (nil, let s?):
            end = s
        default:
            return nil
        }
        // Include the terminator in the returned substring.
        let terminatorEnd = after[end...].starts(with: "\u{07}")
            ? after.index(after: end)
            : after.index(end, offsetBy: 2)
        return String(stream[introducerRange.lowerBound..<terminatorEnd])
    }
}

/// Live surface + collector for a probe test, with a cleanup closure that
/// tears down the terminal view and the `Ghostty.App` instance.
@MainActor
private struct ProbeHarness {
    let terminal: GhosttyTerminalView
    let surface: Ghostty.Surface
    let collector: WriteCollector
    let cleanup: () -> Void
}

/// Collects raw `Data` writes from the ghostty surface write callback and
/// decodes them as a single UTF-8 string. Writes may arrive fragmented or
/// batched across multiple callback invocations, so the collector accumulates
/// everything and lets the caller search the combined stream. Mirrors
/// `GhosttyOSCColorQueryTests.WriteCollector`.
@MainActor
private final class WriteCollector {
    private var chunks: [Data] = []
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(data)
    }

    func combinedString() -> String {
        lock.lock(); defer { lock.unlock() }
        let combined = chunks.reduce(into: Data()) { $0.append($1) }
        return String(data: combined, encoding: .utf8) ?? ""
    }
}
