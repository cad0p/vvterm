// SPDX-License-Identifier: MIT
//
//  GhosttySurfaceUserdataLifetimePinsTests.swift
//  VVTermTests
//
//  Source pins for #310: a ghostty surface must never hold a raw pointer to a
//  `GhosttyTerminalView`. The surface's userdata is a retained
//  `Ghostty.SurfaceCallbackContext`; every callback resolves the view through
//  it, and both `ghostty_surface_free` paths invalidate it first.
//
//  WHAT THESE PINS ASSERT
//    P-A  repo-wide: no `Unmanaged<GhosttyTerminalView>` cast remains anywhere
//         under `VVTerm/` (the scan fails closed when it enumerates no files
//         or misses the `Ghostty.App.swift` sentinel).
//    P-B  every routing site resolves through the chosen helper
//         (`Ghostty.SurfaceCallbackContext.fromOpaque(`): three in
//         `Ghostty.App.swift` (action fallback, readClipboard, closeSurface)
//         and one per platform write callback; the single
//         `ghostty_surface_userdata(` read is paired with that helper; both
//         `setupSurface` bodies assign `surfaceConfig.userdata =
//         callbackContext.userdata` and keep the context alive across
//         `ghostty_surface_new` with `withExtendedLifetime`.
//    P-C  `Ghostty.Surface`: the initializer stores the context, and both free
//         paths (`free()`, `deinit`) call `callbackContext.invalidate()`
//         before `ghostty_surface_free`; the deferred `deinit` block retains
//         the context via `withExtendedLifetime(callbackContext)`.
//    P-D  both `setupWriteCallback` bodies pass `callbackContext.userdata` to
//         `ghostty_surface_set_write_callback`, unwrap the context, and carry
//         no `Unmanaged.passUnretained(self)` view cast.
//
//  WHAT THEY DO NOT SEE. A renamed helper, an aliased userdata pointer, a
//  callback that unwraps the context and then casts the view through a new
//  spelling, or a behavioural regression in the context itself. Comments are
//  stripped before every scan, so a commented-out cast cannot satisfy a pin,
//  but a string literal containing the pinned text could.
//
//  MEASURED COUNTERFACTUALS (each pin red under a targeted mutation, run with
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>`):
//    P-A  re-add `Unmanaged<GhosttyTerminalView>` to the action fallback →
//         `offenders: ["Ghostty.App.swift"]`.
//    P-B  revert the `readClipboard` route to the raw view cast →
//         `expected 3 context routes in Ghostty.App.swift, found 2`.
//    P-C  delete `callbackContext.invalidate()` from `free()` →
//         the invalidate-before-free order assertion fails.
//    P-D  revert the iOS write callback to `passUnretained(self)` →
//         `callbackContext.userdata` count 0 / `passUnretained(self)` present.

import Foundation
import Testing

@testable import VVTerm

struct GhosttySurfaceUserdataLifetimePinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/GhosttySurfaceUserdataLifetimePinsTests.swift`).
    ///
    /// Counterfactual hook: the mutation runs point this at a mutated tree to
    /// prove the pins fail there. Never set in CI. As with the other pin
    /// suites, the variable must reach the test process as
    /// `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's environment (a
    /// plain env var is inert); alternatively hand-mutate the worktree and
    /// restore it.
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // GhosttySurfaceUserdataLifetimePinsTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static let appSource = "VVTerm/GhosttyTerminal/Ghostty.App.swift"
    private static let surfaceSource = "VVTerm/GhosttyTerminal/Ghostty.Surface.swift"
    private static let renderingSetupSource = "VVTerm/GhosttyTerminal/GhosttyRenderingSetup.swift"
    private static let iOSViewSource = "VVTerm/GhosttyTerminal/GhosttyTerminalView+iOS.swift"
    private static let macOSViewSource = "VVTerm/GhosttyTerminal/GhosttyTerminalView+macOS.swift"

    /// The exact helper every routed callback must use.
    private static let contextRoute = "Ghostty.SurfaceCallbackContext.fromOpaque("

    // MARK: - P-A: no raw view casts repo-wide

    /// Repo-wide scan of `VVTerm/**/*.swift` for `Unmanaged<GhosttyTerminalView>`.
    /// This is the pin that makes the fix's core property structural: the
    /// surface userdata must never be unwrapped as the view again.
    @Test
    func testPANoSurfaceUserdataHoldsARawViewCast() throws {
        let scanRoot = repositoryRoot().appendingPathComponent("VVTerm")
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(url)
            }
        }

        // Fail closed: an empty or wrong root must red the pin, not pass it.
        #expect(!files.isEmpty, "P-A: the scan must enumerate Swift files under VVTerm/")
        let sentinel = scanRoot.appendingPathComponent("GhosttyTerminal/Ghostty.App.swift").standardizedFileURL
        #expect(
            files.contains { $0.standardizedFileURL == sentinel },
            "P-A: the scan must include the Ghostty.App.swift sentinel"
        )

        var offenders: [String] = []
        for url in files {
            let text = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
            if !Self.occurrences(of: "Unmanaged<GhosttyTerminalView>", in: text).isEmpty {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            "P-A: no surface callback may cast the userdata to a raw view; offenders: \(offenders.sorted())"
        )
    }

    // MARK: - P-B: every routing site resolves through the context

    /// The three app-level routing sites and the one-per-platform write
    /// callbacks all use the context helper, and the only
    /// `ghostty_surface_userdata(` read is the action fallback paired with it.
    @Test
    func testPBEveryRoutingSiteResolvesThroughTheContext() throws {
        let appText = Self.strippingComments(try source(Self.appSource))
        let appRoutes = Self.flexibleOccurrences(
            of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
            in: appText
        )
        #expect(
            appRoutes.count == 3,
            "P-B: Ghostty.App.swift must route action/readClipboard/closeSurface through the context; found \(appRoutes.count)"
        )
        #expect(
            Self.occurrences(of: "ghostty_surface_userdata(", in: appText).count == 1,
            "P-B: Ghostty.App.swift must read the surface userdata exactly once (the action fallback)"
        )
        #expect(
            Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(ghostty_surface_userdata(surface))",
                in: appText
            ).count == 1,
            "P-B: the action fallback must pair ghostty_surface_userdata(surface) with the context helper"
        )

        for file in [Self.iOSViewSource, Self.macOSViewSource] {
            let text = Self.strippingComments(try source(file))
            let routes = Self.flexibleOccurrences(
                of: "Ghostty.SurfaceCallbackContext .fromOpaque(",
                in: text
            )
            #expect(
                routes.count == 1,
                "P-B: \(file) must route its write callback through the context; found \(routes.count)"
            )
        }
    }

    /// Both `setupSurface` branches install the context as the userdata before
    /// `ghostty_surface_new` and keep it alive across the call (the core emits
    /// set_title/cell_size from inside `Surface.init`).
    @Test
    func testPBBothSetupSurfaceBranchesInstallTheContextUserdata() throws {
        let text = Self.strippingComments(try source(Self.renderingSetupSource))
        let anchors = Self.occurrences(of: "func setupSurface(", in: text)
        #expect(anchors.count == 2, "P-B: both platform setupSurface functions must exist")

        for anchor in anchors {
            let body = try Self.bracedBlock(after: anchor, in: text)
            #expect(
                Self.occurrences(of: "surfaceConfig.userdata = callbackContext.userdata", in: text, range: body).count == 1,
                "P-B: setupSurface must assign surfaceConfig.userdata = callbackContext.userdata exactly once"
            )
            #expect(
                Self.occurrences(of: "surfaceConfig.userdata = Unmanaged", in: text, range: body).count == 0,
                "P-B: setupSurface must not assign a raw Unmanaged pointer as userdata"
            )
            // Positive control: this is the real platform body (it still sets
            // the creation-time platform view pointer).
            #expect(
                Self.occurrences(of: "Unmanaged.passUnretained(view).toOpaque()", in: text, range: body).count == 1,
                "P-B: the resolved span must be a real setupSurface body with its platform view pointer"
            )

            let retain = try #require(
                Self.occurrences(of: "withExtendedLifetime(callbackContext", in: text, range: body).first,
                "P-B: setupSurface must keep the context alive across ghostty_surface_new"
            )
            let create = try #require(
                text.range(of: "ghostty_surface_new(", range: body),
                "P-B: setupSurface must call ghostty_surface_new"
            )
            #expect(
                retain.lowerBound < create.lowerBound,
                "P-B: the context must be retained across the ghostty_surface_new call"
            )
        }
    }

    // MARK: - P-C: invalidate before every free, retain across the deferred free

    /// `Ghostty.Surface` stores the context in its initializer, invalidates it
    /// before `ghostty_surface_free` on both free paths, and the deferred block
    /// keeps it alive with `withExtendedLifetime`.
    @Test
    func testPCSurfaceInvalidatesBeforeEveryFreeAndRetainsTheContext() throws {
        let text = Self.strippingComments(try source(Self.surfaceSource))

        let initAnchor = try #require(
            Self.occurrences(of: "init(cSurface: ghostty_surface_t, callbackContext: Ghostty.SurfaceCallbackContext)", in: text).first,
            "P-C: Surface must keep its context-carrying initializer"
        )
        let initBody = try Self.bracedBlock(after: initAnchor, in: text)
        #expect(
            Self.occurrences(of: "self.callbackContext = callbackContext", in: text, range: initBody).count == 1,
            "P-C: the initializer must store the callback context"
        )

        let freeAnchor = try #require(
            Self.occurrences(of: "func free()", in: text).first,
            "P-C: Surface must keep its synchronous free()"
        )
        let freeBody = try Self.bracedBlock(after: freeAnchor, in: text)
        let freeInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: freeBody),
            "P-C: free() must invalidate the context"
        )
        let freeCall = try #require(
            text.range(of: "ghostty_surface_free(", range: freeBody),
            "P-C: free() must call ghostty_surface_free"
        )
        #expect(
            freeInvalidate.lowerBound < freeCall.lowerBound,
            "P-C: free() must invalidate the context before ghostty_surface_free"
        )

        let deinitAnchors = Self.occurrences(of: "deinit", in: text)
        #expect(deinitAnchors.count == 1, "P-C: Surface must have exactly one deinit")
        let deinitBody = try Self.bracedBlock(after: try #require(deinitAnchors.first), in: text)
        let deinitInvalidate = try #require(
            text.range(of: "callbackContext.invalidate()", range: deinitBody),
            "P-C: deinit must invalidate the context"
        )
        let deinitFree = try #require(
            text.range(of: "ghostty_surface_free(", range: deinitBody),
            "P-C: deinit must call ghostty_surface_free"
        )
        #expect(
            deinitInvalidate.lowerBound < deinitFree.lowerBound,
            "P-C: deinit must invalidate the context before ghostty_surface_free"
        )

        #expect(
            Self.occurrences(of: "let context = callbackContext", in: text, range: deinitBody).count == 1,
            "P-C: deinit must bind a strong local for the deferred block to capture"
        )
        let asyncAnchor = try #require(
            text.range(of: "DispatchQueue.main.async", range: deinitBody),
            "P-C: deinit must defer the free to the main queue"
        )
        let asyncBody = try Self.bracedBlock(after: asyncAnchor, in: text)
        #expect(
            Self.occurrences(of: "withExtendedLifetime(context)", in: text, range: asyncBody).count == 1,
            "P-C: the deferred free block must retain the captured context with withExtendedLifetime(context)"
        )
        #expect(
            Self.occurrences(of: "ghostty_surface_free(", in: text, range: asyncBody).count == 1,
            "P-C: the deferred block must be the single ghostty_surface_free call"
        )
    }

    // MARK: - P-D: the write callbacks use the context userdata

    /// Both platform `setupWriteCallback` bodies pass `callbackContext.userdata`
    /// to the C API and unwrap the context, with no view-address userdata left.
    @Test
    func testPDWriteCallbacksUseTheContextUserdata() throws {
        for file in [Self.iOSViewSource, Self.macOSViewSource] {
            let text = Self.strippingComments(try source(file))
            let anchor = try #require(
                Self.occurrences(of: "func setupWriteCallback()", in: text).first,
                "P-D: \(file) must keep setupWriteCallback()"
            )
            let body = try Self.bracedBlock(after: anchor, in: text)

            #expect(
                Self.occurrences(of: "ghostty_surface_set_write_callback(", in: text, range: body).count == 1,
                "P-D: \(file) must install exactly one write callback"
            )
            #expect(
                Self.occurrences(of: "callbackContext.userdata", in: text, range: body).count == 1,
                "P-D: \(file) must pass the context userdata to the write callback"
            )
            #expect(
                Self.occurrences(of: Self.contextRoute, in: text, range: body).count == 1,
                "P-D: \(file) must resolve the write callback userdata through the context"
            )
            #expect(
                Self.occurrences(of: "Unmanaged.passUnretained(self).toOpaque()", in: text, range: body).count == 0,
                "P-D: \(file) must not pass the view address as write-callback userdata"
            )
            #expect(
                Self.occurrences(of: "Unmanaged<GhosttyTerminalView>", in: text, range: body).count == 0,
                "P-D: \(file) must not cast the write-callback userdata to the view"
            )
        }
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim (so a `//` inside a literal is not read as
    /// a comment); the scanner covers `"…"` (with `\` escapes) and `"""…"""`
    /// but not raw strings (`#"…"#`) or comments inside an interpolation.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringDelimiter: Int? = nil  // 1 for `"…"`, 3 for `"""…"""`
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if let delimiter = stringDelimiter {
                result.append(character)
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if delimiter == 1, character == "\"" {
                    stringDelimiter = nil
                    continue
                }
                if delimiter == 3,
                   character == "\"",
                   index + 1 < characters.count,
                   characters[index] == "\"",
                   characters[index + 1] == "\"" {
                    result.append("\"\"")
                    index += 2
                    stringDelimiter = nil
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append("  ")
                index += 2
                continue
            }
            if character == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    stringDelimiter = 3
                    result.append("\"\"\"")
                    index += 3
                } else {
                    stringDelimiter = 1
                    result.append("\"")
                    index += 1
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// The body span `{ … }` of the brace-delimited block that opens at
    /// `open`, found by a character-level depth walk.
    private static func bracedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "{", "the explicit block open must be a `{`")
        var depth = 0
        var close: String.Index?
        var index = open
        while index < text.endIndex, close == nil {
            if text[index] == "{" {
                depth += 1
            } else if text[index] == "}" {
                depth -= 1
                if depth == 0 { close = index }
            }
            index = text.index(after: index)
        }
        let blockClose = try #require(close, "the pin block's braces must balance")
        return text.index(after: open)..<blockClose
    }

    /// The body span of the first brace-delimited block after `anchor`.
    ///
    /// The anchor must be **brace-less** for the intended block to be the one
    /// it opens: `bracedBlock` binds the first `{` after the anchor.
    private static func bracedBlock(
        after anchor: Range<String.Index>,
        in text: String
    ) throws -> Range<String.Index> {
        let open = try #require(
            text[anchor.upperBound...].firstIndex(of: "{"),
            "the pin anchor must be followed by a `{`"
        )
        return try bracedBlock(openingAt: open, in: text)
    }

    /// Every occurrence of `needle` in `text` (optionally within `range`),
    /// in source order.
    private static func occurrences(
        of needle: String,
        in text: String,
        range: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let searchRange = range ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = searchRange.lowerBound
        while let found = text.range(of: needle, range: searchStart..<searchRange.upperBound) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }

    /// Every occurrence of `needle` in `text`, where `needle` is split on
    /// single spaces and each piece may be separated by any amount of
    /// whitespace (including a newline) or by none at all. This matches the
    /// pinned call expression whether the source keeps it on one line or wraps
    /// it across lines.
    private static func flexibleOccurrences(
        of needle: String,
        in text: String,
        range searchRange: Range<String.Index>? = nil
    ) -> [Range<String.Index>] {
        let tokens = needle.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return [] }
        let bounds = searchRange ?? text.startIndex..<text.endIndex
        var result: [Range<String.Index>] = []
        var searchStart = bounds.lowerBound
        while let candidate = text.range(of: first, range: searchStart..<bounds.upperBound) {
            if let end = flexibleMatchEnd(tokens: tokens, in: text, after: candidate, limit: bounds.upperBound) {
                result.append(candidate.lowerBound..<end)
                searchStart = end
            } else {
                searchStart = text.index(after: candidate.lowerBound)
            }
        }
        return result
    }

    /// The end index of a match whose first token is `firstMatch`, or nil when
    /// the remaining tokens do not line up in order.
    private static func flexibleMatchEnd(
        tokens: [String],
        in text: String,
        after firstMatch: Range<String.Index>,
        limit: String.Index
    ) -> String.Index? {
        var upper = firstMatch.upperBound
        for token in tokens.dropFirst() {
            var cursor = upper
            while cursor < limit, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard let tokenRange = text.range(of: token, range: cursor..<limit),
                  tokenRange.lowerBound == cursor else { return nil }
            upper = tokenRange.upperBound
        }
        return upper
    }
}
