// SPDX-License-Identifier: MIT
//
//  BrowserMFACeremonyFailFastPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #401: the Browser MFA fail-fast test must observe
//  the A7 guard through the injected listener seam, not a wall-clock race.
//
//  Why source pins: the regression shape here is structural (a wall clock
//  racing the product path). A behavioural test cannot pin "no 30 s timer
//  exists" — the original flake reds only under host starvation, which a
//  deterministic run cannot manufacture. These pins read the production and
//  test sources as text and assert the shape:
//
//  1. the fail-fast method carries no wall clock — `Task.sleep`/`sleep`,
//     `ContinuousClock`, `Date`, `DispatchTime`, `Timer` — the deleted
//     `failFastBudget` is refused file-wide (the body is the brace-depth
//     block, so nested declarations are inside the scan), and the method
//     still drives `StubBrowserMFAListener` / `waitCount`, keeps one bare
//     catch-all (`catch {`), and asserts the typed `.safariFailed` contract
//     with the exact A7 message;
//  2. `BrowserMFACeremony.run` builds its listener through
//     `makeListener(logger)` (a re-hardcoded `BrowserMFAListener(logger:)`
//     reds);
//  3. the init's `makeListener` parameter default still constructs the real
//     `BrowserMFAListener(`, so the seam cannot silently become a no-op in
//     production;
//  4. the #405 approval-page presentation test carries no wall clock and no
//     polling shape, drives the injected `StubBrowserMFAListener` seam, and
//     the deleted #397 `approvalPagePresentationTolerance` is refused
//     file-wide;
//  5. the #405 redaction-suite ceremony test carries no wall clock, no
//     `presentDeadline`, no `run.cancel()` and no `try?`, and keeps the
//     injected stub plus its `waitForLog` leak scans.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse source as text. Pins
//  1/4/5's body is the brace-depth block after the declaration anchor, so
//  nested declarations are inside the negative scan (the file-wide
//  `failFastBudget` / `approvalPagePresentationTolerance` refusals cannot be
//  truncated); any wall clock outside the pinned spellings — a helper, or
//  an API such as `clock_gettime` — still escapes, and a helper-mediated
//  wait outside a pinned method body is not covered (the redaction suite's
//  `waitForLog` is exactly that; #405 §3.4 names it). A listener
//  obtained through a renamed factory escapes pin 2's token; a second
//  initializer written with a declaration keyword (`convenience init(` /
//  `override init(` / `required init(`) is refused explicitly (the
//  `\n    init(` anchor alone only counts unkeyworded declarations), and
//  any other second construction site reds pin 3's file-wide
//  `BrowserMFAListener(` count. The pins catch the direct regression shapes
//  and fail closed when their anchors move. `StubBrowserMFAListenerError`
//  is asserted file-wide rather than in the method slice because the test
//  body never names the type (the catch-all prints the thrown value); the
//  slice's material proof is the injected `StubBrowserMFAListener` plus its
//  `waitCount` diagnostic token.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (measured in the #401 PR report). The variable must actually
//  reach the test process: export `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>`
//  into xcodebuild's own environment. Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct BrowserMFACeremonyFailFastPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Teleport/BrowserMFACeremonyFailFastPinsTests.swift`).
    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BrowserMFACeremonyFailFastPinsTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
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

    /// The body span `{ … }` of the brace-delimited block that opens at `open`,
    /// found by a character-level depth walk.
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

    /// The body span of the first brace-delimited block after `anchor`. The
    /// anchor must be brace-less for the intended block to be the one it opens.
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

    /// The contents of the parenthesized parameter list that opens at `open`,
    /// found by a character-level depth walk. Not string-aware: the pin only
    /// reads parameter lists with no parens inside string literals.
    private static func parenthesizedBlock(
        openingAt open: String.Index,
        in text: String
    ) throws -> Range<String.Index> {
        try #require(text[open] == "(", "the explicit block open must be a `(`")
        var depth = 0
        var close: String.Index?
        var index = open
        while index < text.endIndex, close == nil {
            if text[index] == "(" {
                depth += 1
            } else if text[index] == ")" {
                depth -= 1
                if depth == 0 { close = index }
            }
            index = text.index(after: index)
        }
        let blockClose = try #require(close, "the pin block's parens must balance")
        return text.index(after: open)..<blockClose
    }

    /// Every occurrence of `needle` in `text` (optionally within `range`), in
    /// source order.
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

    // MARK: - Pins

    /// Pin 1 (issue #401): the fail-fast test must drive the A7 guard through
    /// the injected listener, with no wall clock racing the product path. The
    /// body is the brace-depth block after the declaration anchor (#405), so
    /// a `Task.sleep`/`ContinuousClock` budget re-added anywhere inside it
    /// reds; a deleted method reds the anchor count.
    @Test
    func testTheFailFastTestKeepsTheStructuralShape() throws {
        let path = "VVTermTests/Features/Teleport/BrowserMFACeremonyLoopbackURLTests.swift"
        let text = Self.strippingComments(try source(path))

        // File-level fixture census: the stub's immediate-throw error exists.
        #expect(
            text.contains("enum StubBrowserMFAListenerError"),
            "the fail-fast fixture must declare StubBrowserMFAListenerError — re-derive this pin (issue #401)"
        )
        #expect(
            text.contains("throw StubBrowserMFAListenerError.waitReached"),
            "StubBrowserMFAListener.waitForResponse() must throw immediately (never suspend), so the reverted-guard counterfactual reds instead of hanging — re-derive this pin (issue #401)"
        )

        // File-wide refusal, not slice-bounded: the 30 s `failFastBudget`
        // constant was deleted in #401 and must not return anywhere in this
        // file. This check cannot be truncated by a nested declaration
        // inside the fail-fast method (lens 1 F1).
        #expect(
            !text.contains("failFastBudget"),
            "the 30 s `failFastBudget` race was deleted in #401; it must not return anywhere in this file"
        )

        let anchors = Self.occurrences(
            of: "func testCeremonyFailsFastWhenTheBrowserSessionDidNotStart",
            in: text
        )
        #expect(
            anchors.count == 1,
            "the fail-fast test must exist exactly once — re-derive this pin (issue #401)"
        )
        let anchor = try #require(anchors.first)

        // #405 lens 1 F1: the body is the brace-depth block after the
        // declaration anchor. Unlike the #401 boundary search (next `func` /
        // `private static let`), this is invariant to what follows the method
        // and scans nested declarations too (counterfactual CF-6).
        let bodyRange = try Self.bracedBlock(after: anchor, in: text)
        let body = String(text[bodyRange])
        #expect(
            body.contains { !$0.isWhitespace },
            "the fail-fast method slice must not be empty — re-derive this pin (issue #401)"
        )

        // Negative: no wall clock may compete with the guard. The first
        // three tokens pin the #401 regression spellings explicitly; the
        // rest close the direct non-helper spellings (the header defeat list
        // names what still escapes this token set).
        #expect(
            !body.contains("Task.sleep"),
            "the fail-fast test must not race a `Task.sleep` budget — the A7 guard is observed through the injected listener stub (issue #401)"
        )
        #expect(
            !body.contains("ContinuousClock"),
            "the fail-fast test must not race a `ContinuousClock` deadline — the A7 guard is observed through the injected listener stub (issue #401)"
        )
        #expect(
            !body.contains("failFastBudget"),
            "the 30 s `failFastBudget` race was deleted in #401; it must not return (the file-wide check above cannot be truncated)"
        )
        #expect(
            !body.contains("sleep"),
            "the fail-fast test must not race any sleep-based budget (`Task.sleep`, `Thread.sleep`, `Task<Never, Never>.sleep`) — the A7 guard is observed through the injected listener stub (issue #401)"
        )
        #expect(
            !body.contains("Timer"),
            "the fail-fast test must not race a `Timer` budget — the A7 guard is observed through the injected listener stub (issue #401)"
        )
        #expect(
            !body.contains("DispatchTime"),
            "the fail-fast test must not race a `DispatchTime` deadline — the A7 guard is observed through the injected listener stub (issue #401)"
        )
        #expect(
            !body.contains("Date"),
            "the fail-fast test must not race a `Date` deadline — the A7 guard is observed through the injected listener stub (issue #401)"
        )

        // Positive: the stub seam is still driven, and the catch-all remains.
        #expect(
            body.contains("StubBrowserMFAListener"),
            "the fail-fast test must drive the injected StubBrowserMFAListener — re-derive this pin (issue #401)"
        )
        #expect(
            body.contains("makeListener:"),
            "the fail-fast test must inject the stub through the ceremony's `makeListener` seam — re-derive this pin (issue #401)"
        )
        #expect(
            body.contains("case .safariFailed"),
            "the fail-fast test must keep the typed `.safariFailed` catch (a bare catch-all alone no longer enforces the product error contract) — re-derive this pin (issue #401)"
        )
        #expect(
            body.contains("the in-app browser session did not start"),
            "the fail-fast test must keep the exact A7 message assertion — re-derive this pin (issue #401)"
        )
        // `waitCount` is a diagnostic pin token, not independent evidence:
        // the stub's `waitForResponse()` always throws, so the typed
        // `.safariFailed` catch above is the primary proof and
        // `waitCount == 0` cannot fail while it passes. The token keeps the
        // guard-before-wait ordering explicit if the typed catch is weakened.
        #expect(
            body.contains("waitCount"),
            "the fail-fast test must assert the stub's `waitCount` (the guard fired before the listener wait) — re-derive this pin (issue #401)"
        )
        #expect(
            Self.occurrences(of: "catch {", in: body).count == 1,
            "the fail-fast test must keep exactly one bare catch-all (`catch {`), so a non-ceremony error reds instead of hanging — re-derive this pin (issue #401)"
        )
    }

    /// Pin 2 (issue #401): `BrowserMFACeremony.run` must build its listener
    /// through the injected factory; a re-hardcoded production listener makes
    /// the seam a no-op.
    @Test
    func testTheCeremonyRunDrivesTheInjectedListener() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Teleport/Infrastructure/BrowserMFACeremony.swift")
        )
        let anchors = Self.occurrences(of: "func run(", in: text)
        #expect(
            anchors.count == 1,
            "BrowserMFACeremony must declare exactly one `func run(` — re-derive this pin (issue #401)"
        )
        let anchor = try #require(anchors.first)
        let bodyRange = try Self.bracedBlock(after: anchor, in: text)
        let body = String(text[bodyRange])

        #expect(
            body.contains("makeListener(logger)"),
            "BrowserMFACeremony.run must construct its listener through `makeListener(logger)` — re-derive this pin (issue #401)"
        )
        #expect(
            !body.contains("BrowserMFAListener("),
            "BrowserMFACeremony.run must not re-hardcode the real listener — re-derive this pin (issue #401)"
        )
    }

    /// Pin 3 (issue #401): the init's `makeListener` default must still build
    /// the real production listener, so tests alone cannot silently replace
    /// the seam target.
    @Test
    func testTheInitDefaultBuildsTheRealListener() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Teleport/Infrastructure/BrowserMFACeremony.swift")
        )
        let anchors = Self.occurrences(of: "\n    init(", in: text)
        #expect(
            anchors.count == 1,
            "BrowserMFACeremony must declare exactly one init (a `\\n    init(` anchor; `super.init()` does not match) — re-derive this pin (issue #401)"
        )
        let anchor = try #require(anchors.first)
        // The `\n    init(` anchor only matches an unkeyworded initializer at
        // class indent; refuse the keyword spellings explicitly so a second
        // initializer cannot escape the exactly-one anchor (lens 2 F6). Any
        // second construction site still reds the file-wide
        // `BrowserMFAListener(` count below.
        for keyword in ["convenience init(", "override init(", "required init("] {
            #expect(
                !text.contains(keyword),
                "a second initializer written as `\(keyword)` escapes the `\\n    init(` anchor — re-derive this pin (issue #401)"
            )
        }
        // `init(` already carries the opening paren: walk the parameter list
        // from the paren itself, not from the first paren inside it.
        let parameterRange = try Self.parenthesizedBlock(
            openingAt: text.index(before: anchor.upperBound),
            in: text
        )
        let parameters = String(text[parameterRange])

        #expect(
            parameters.contains("makeListener:"),
            "the init must keep the `makeListener` parameter — re-derive this pin (issue #401)"
        )
        #expect(
            parameters.contains("BrowserMFAListener("),
            "the init's makeListener default must construct the real BrowserMFAListener — re-derive this pin (issue #401)"
        )
        #expect(
            Self.occurrences(of: "BrowserMFAListener(", in: text).count == 1,
            "the real BrowserMFAListener must be constructed only by the init's default factory; a second construction site means the seam was bypassed — re-derive this pin (issue #401)"
        )
    }

    /// Pin 4 (issue #405): the approval-page presentation test must drive the
    /// ceremony through the injected listener seam, with no wall clock (or
    /// polling shape) racing the ceremony's MainActor hops. The deleted #397
    /// `approvalPagePresentationTolerance` is refused file-wide.
    @Test
    func testTheApprovalPageTestKeepsTheStructuralShape() throws {
        let path = "VVTermTests/Features/Teleport/BrowserMFACeremonyLoopbackURLTests.swift"
        let text = Self.strippingComments(try source(path))

        // File-wide refusal, not body-bounded: the 45 s constant was deleted
        // in #405 and must not return anywhere in this file.
        #expect(
            !text.contains("approvalPagePresentationTolerance"),
            "the #397 45 s `approvalPagePresentationTolerance` race was deleted in #405; it must not return anywhere in this file"
        )

        let anchors = Self.occurrences(
            of: "func testCeremony_opensTheServerApprovalPageForTheChallengeRequestID",
            in: text
        )
        #expect(
            anchors.count == 1,
            "the approval-page presentation test must exist exactly once — re-derive this pin (issue #405)"
        )
        let anchor = try #require(anchors.first)
        let bodyRange = try Self.bracedBlock(after: anchor, in: text)
        let body = String(text[bodyRange])
        #expect(
            body.contains { !$0.isWhitespace },
            "the approval-page test body must not be empty — re-derive this pin (issue #405)"
        )

        // Negative: no wall clock and no polling shape may compete with the
        // terminating await (the header defeat list names what escapes).
        for token in [
            "ContinuousClock", "Task.sleep", "sleep", "Timer", "DispatchTime",
            "Date", "deadline", "Tolerance", "presentedURLs.isEmpty", "Task.yield",
        ] {
            #expect(
                !body.contains(token),
                "the approval-page test must not race `\(token)` — it awaits the terminating stub listener instead (issue #405)"
            )
        }

        // Positive: the seam is driven, the terminal error is explicit, and
        // the exact-URL assertion survives.
        #expect(
            body.contains("makeListener:"),
            "the approval-page test must inject the stub through the ceremony's `makeListener` seam — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("StubBrowserMFAListener"),
            "the approval-page test must drive the injected StubBrowserMFAListener — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("StubBrowserMFAListenerError"),
            "the approval-page test must keep the typed terminal-error catch (`catch is StubBrowserMFAListenerError`), not discard the error — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("client.requestID"),
            "the approval-page test must keep the exact approval-URL assertion (host + request id) — re-derive this pin (issue #405)"
        )
    }

    /// Pin 5 (issue #405): the redaction suite's ceremony presentation test
    /// must drive the ceremony through the injected listener seam, with no
    /// wall clock, no `presentDeadline` and no `run.cancel()` race, and must
    /// keep the leak scans (`secret_key=`, the full request id).
    @Test
    func testTheRedactionCeremonyTestKeepsTheStructuralShape() throws {
        let path = "VVTermTests/Features/Teleport/TeleportRedactionTests.swift"
        let text = Self.strippingComments(try source(path))

        let anchors = Self.occurrences(
            of: "func testBrowserMFACeremony_neverLogsTheSecretOrTheFullRequestID",
            in: text
        )
        #expect(
            anchors.count == 1,
            "the redaction ceremony test must exist exactly once — re-derive this pin (issue #405)"
        )
        let anchor = try #require(anchors.first)
        let bodyRange = try Self.bracedBlock(after: anchor, in: text)
        let body = String(text[bodyRange])
        #expect(
            body.contains { !$0.isWhitespace },
            "the redaction ceremony test body must not be empty — re-derive this pin (issue #405)"
        )

        // Negative: pin 1's full wall-clock set, the deleted 15 s
        // `presentDeadline`, the `run.cancel()` teardown race, `try?`, and
        // the polling shape.
        for token in [
            "ContinuousClock", "Task.sleep", "sleep", "Timer", "DispatchTime",
            "Date", "deadline", "presentDeadline", "run.cancel()", "try?",
            "presentedURLs.isEmpty", "Task.yield",
        ] {
            #expect(
                !body.contains(token),
                "the redaction ceremony test must not race `\(token)` — it awaits the terminating stub listener instead (issue #405)"
            )
        }

        // Positive: the seam is driven and the leak scans survive.
        #expect(
            body.contains("makeListener:"),
            "the redaction ceremony test must inject the stub through the ceremony's `makeListener` seam — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("StubBrowserMFAListener"),
            "the redaction ceremony test must drive the injected StubBrowserMFAListener — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("waitForLog"),
            "the redaction ceremony test must keep the `waitForLog` readback of the logged payloads — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("fullRequestID"),
            "the redaction ceremony test must keep the full-request-id leak scan — re-derive this pin (issue #405)"
        )
        #expect(
            body.contains("secret_key="),
            "the redaction ceremony test must keep the callback-URL leak scan — re-derive this pin (issue #405)"
        )
    }
}
