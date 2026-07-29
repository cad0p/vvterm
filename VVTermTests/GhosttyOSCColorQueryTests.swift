import Foundation
import CoreGraphics
import Testing
@testable import VVTerm

/// Verifies that OSC 10/11 color-query sequences generate a response on the
/// terminal's write callback — the path that routes data back to the remote
/// SSH channel. Programs like vim, tmux, and starship rely on these queries
/// to adapt their UI to a dark or light terminal theme.
///
/// Sequence reference (xterm / Ghostty docs):
///   - `ESC ] 10 ; ? ST` → reply `ESC ] 10 ; rgb:rrrr/gggg/bbbb ST`
///   - `ESC ] 11 ; ? ST` → reply `ESC ] 11 ; rgb:rrrr/gggg/bbbb ST`
///   - `ST` is BEL (0x07) or ESC \ (0x1b 0x5c)
///
/// Ghostty's default `osc-color-report-format` is `16-bit`, so each color
/// component is reported as 4 lowercase hex digits.
@Suite(.serialized)
@MainActor
struct GhosttyOSCColorQueryTests {

    @Test
    func osc10QueryEmitsForegroundColorResponse() throws {
        let stream = try captureWriteOutput(afterFeeding: "\u{1B}]10;?\u{07}")

        let response = try #require(firstOSCResponse(in: stream, index: "10"))
        #expect(response.hasPrefix("\u{1B}]10;rgb:"))
        assertValidTerminator(response)
        assertValidRGBPayload(response, strippingPrefix: "\u{1B}]10;")
    }

    @Test
    func osc11QueryEmitsBackgroundColorResponse() throws {
        let stream = try captureWriteOutput(afterFeeding: "\u{1B}]11;?\u{07}")

        let response = try #require(firstOSCResponse(in: stream, index: "11"))
        #expect(response.hasPrefix("\u{1B}]11;rgb:"))
        assertValidTerminator(response)
        assertValidRGBPayload(response, strippingPrefix: "\u{1B}]11;")
    }

    @Test
    func osc10QueryWithStringTerminatorEmitsResponse() throws {
        // ST terminator form: ESC \
        let stream = try captureWriteOutput(afterFeeding: "\u{1B}]10;?\u{1B}\\")

        let response = try #require(firstOSCResponse(in: stream, index: "10"))
        #expect(response.hasPrefix("\u{1B}]10;rgb:"))
    }

    @Test
    func osc10AndOsc11QueriesAreIndependent() throws {
        let stream = try captureWriteOutput(
            afterFeeding: "\u{1B}]10;?\u{07}\u{1B}]11;?\u{07}"
        )

        #expect(firstOSCResponse(in: stream, index: "10") != nil)
        #expect(firstOSCResponse(in: stream, index: "11") != nil)
    }

    // MARK: - Helpers

    /// Scans the captured host stream for the first complete OSC response of
    /// the form `ESC ] <index> ; rgb:... ST`. Returns the substring spanning
    /// from the introducer to the terminator (inclusive), or nil if absent.
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

    private func assertValidTerminator(_ response: String) {
        #expect(response.hasSuffix("\u{07}") || response.hasSuffix("\u{1B}\\"))
    }

    private func assertValidRGBPayload(_ response: String, strippingPrefix prefix: String) {
        let body = response
            .replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: "\u{07}", with: "")
            .replacingOccurrences(of: "\u{1B}\\", with: "")
        #expect(body.hasPrefix("rgb:"))
        let components = body.replacingOccurrences(of: "rgb:", with: "").split(separator: "/")
        #expect(components.count == 3)
        for component in components {
            #expect(component.count == 4 || component.count == 2)
            #expect(component.allSatisfy { $0.isHexDigit })
        }
    }

    /// Creates a real GhosttyTerminalView in custom-I/O mode, installs a write
    /// callback, feeds the given escape sequence, and returns the full UTF-8
    /// stream the surface emitted back to the "host".
    @discardableResult
    private func captureWriteOutput(afterFeeding input: String) throws -> String {
        let app = Ghostty.App()
        let appHandle = try #require(app.app)
        let terminal = GhosttyTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSTemporaryDirectory(),
            ghosttyApp: appHandle,
            appWrapper: app,
            paneId: "osc-color-query",
            useCustomIO: true
        )
        defer {
            terminal.cleanup()
            app.cleanup()
        }

        let surface = try #require(terminal.surface)
        _ = try #require(surface.unsafeCValue)

        let collector = WriteCollector()
        terminal.writeCallback = { data in
            collector.append(data)
        }
        terminal.setupWriteCallback()
        terminal.acceptsTerminalInput = true

        surface.feedText(input)

        // libghostty emits OSC responses synchronously during feed_data on the
        // custom-I/O path, but pump the run loop a few times to flush any
        // deferred dispatch used by the redraw scheduler.
        for _ in 0..<10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }

        return collector.combinedString()
    }
}

/// Collects raw `Data` writes from the ghostty surface write callback and
/// decodes them as a single UTF-8 string. Writes may arrive fragmented or
/// batched across multiple callback invocations, so the collector accumulates
/// everything and lets the caller search the combined stream.
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
