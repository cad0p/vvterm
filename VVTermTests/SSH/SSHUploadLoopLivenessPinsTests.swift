// SPDX-License-Identifier: MIT
//
//  SSHUploadLoopLivenessPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #291: every SCP/exec upload retry loop captures its
//  `LIBSSH2_CHANNEL *` and its backing session before the loop and re-enters
//  libssh2 after `await waitForSocket()` without re-validating them. The fix
//  re-checks the session at the top of every loop body:
//
//      guard isActive,
//            !hasBeenCleaned,
//            let currentSession = libssh2Session,
//            currentSession == session,
//            socket >= 0,
//            atomicSocket.isUsable else {
//          throw SSHError.notConnected
//      }
//
//  with `session` captured by each caller at its top and threaded into
//  `finishUploadChannel(_:session:drainOutput:)` and
//  `drainChannelOutput(_:session:)`.
//
//  THE TEARDOWN WINDOW IS LATENT, NOT REACHABLE TODAY. `waitForSocket()` is a
//  same-actor call into a fully synchronous body (`poll(&pfd, 1, 5)`, no
//  `await`/`Task.yield()`); the only awaits in the family are same-actor
//  calls into bodies with no suspension; and actor re-entry needs a
//  suspension — so `disconnect()`/`cleanupLibssh2()` cannot interleave with
//  these loops at the commit that added them (independently verified for the
//  merged #288/#290 family by a 2M-iteration same-actor probe). These pins
//  enforce the structural invariant and its placement; they are NOT a fix for
//  a reachable use-after-free.
//
//  ONE REACHABLE BEHAVIOUR CHANGE: `SSHSession.abort()` is `nonisolated` and
//  is called by `SSHClient.disconnectSSHSession`'s 4 s watchdog, so a client
//  `disconnect()` during an upload longer than the timeout interrupts the
//  socket while the upload still holds the actor — `atomicSocket.isUsable`
//  flips false while `isActive`/`libssh2Session`/`socket` are unchanged. The
//  guard now throws `notConnected` there where the old code continued on an
//  interrupted socket. That is desirable fail-fast, and it is labelled as a
//  behaviour change in the commit and PR bodies.
//
//  `drainChannelOutput` CLASSIFICATION: its loops `break` on
//  `EAGAIN`/0, so they never park and are not a re-entry-after-wait site.
//  They get the same loop-top guard for uniformity and defence-in-depth; the
//  guard is only a net win because the callers' catches are
//  liveness-conditional (commit 1), so an aborted drain cannot relocate the
//  use-after-free into the catch.
//
//  LOOP 7's SECOND GUARD: `finishUploadChannel`'s wait-eof loop drains
//  output (`await drainChannelOutput`) before `libssh2_channel_wait_eof`, so
//  the loop-top guard does not dominate that re-entry if the drain ever
//  suspends. The same predicate is repeated immediately after the drain and
//  before `wait_eof`; that repetition is pinned separately.
//
//  Why source pins instead of a behavioural test: this target has no
//  SSH-server/libssh2 fixture (`LoopbackTLSServerTestSupport` is TLS-only and
//  `SSHStartupIntegrationTests` is env-gated plain SSH); the channels are
//  function locals with no setter; no test calls
//  `libssh2_session_init`/`libssh2_channel_open`; and a synthetic
//  `OpaquePointer` faults inside libssh2 before any assertion can run. The
//  normal and failing paths are exercised by the dispatched `teleport-e2e.yml`
//  upload legs — not a reproduction of the parked window, which has none.
//
//  WHAT THESE PINS ASSERT (and what they do not see). Each pin matches the
//  guard's EXACT whitespace-normalized predicate text and asserts it is the
//  loop body's first statement — only `try Task.checkCancellation()` may
//  precede it — so a `||` weakening, a dropped term, a guard nested in an
//  early `if`, and a guard moved below the wait all go red. Per-loop
//  `count == 1` assertions for the wait and the re-entry deliberately make a
//  duplicated loop or re-entry red. It is still a tripwire, not a proof:
//  invisible remain a suspension added to the wait helper or to a loop body,
//  an unguarded re-entry using a token the pin does not list, and any
//  behavioural change outside the pinned text. Comments are stripped before
//  every scan, so a commented-out guard cannot satisfy an assertion, but a
//  string literal containing the guard text could. A renamed variable or a
//  re-derived `session` inside a helper makes the exact-text match red — a
//  deliberate firing that forces re-affirmation.
//
//  NOT PINNED HERE: the callers' entry guards and the two non-loop
//  libssh2 calls on captured pointers (see #291 plan §1) — the latter are
//  safe only by adjacency (they run after a non-EAGAIN loop exit with no
//  intervening await), and an inserted `await` before them breaks that
//  invariant silently; this pin does not see it.
//

import Foundation
import Testing

@testable import VVTerm

struct SSHUploadLoopLivenessPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHUploadLoopLivenessPinsTests.swift`).
    private static func repositoryRoot() -> URL {
        // Counterfactual hook: the guard-sensitivity runs point this at a
        // mutated tree to prove the pins fail there. Never set in CI. The
        // `TEST_RUNNER_` form reaches the test process under `xcodebuild
        // test` (measured and documented in the merged #288/#290 pin suites);
        // a plain env var is inert, and `test-without-building -xctestrun`
        // does not strip the prefix.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHUploadLoopLivenessPinsTests.swift
            .deletingLastPathComponent()  // SSH/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func slicedSource() throws -> (text: String, actorSpan: Range<String.Index>) {
        let text = Self.strippingComments(try Self.source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration"
        )
        return (text, actorAnchor.upperBound..<text.endIndex)
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim. Duplicated from the merged pin suites so
    /// each family's pin file is self-contained and reverts independently.
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

    /// The body span of the first brace-delimited block after `anchor`. The
    /// anchor must be brace-less for the intended block to be the one it
    /// opens (`bracedBlock` binds the first `{` after the anchor).
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

    /// The whitespace-normalized form of `text`: every run of whitespace
    /// collapses to a single space (empty for an all-whitespace span).
    private static func normalizedWhitespace(_ text: Substring) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The range of the first whitespace-flexible occurrence of `needle`
    /// within `text[searchRange]`. `needle` is split on single spaces, and
    /// each piece must occur in order, separated by at least one whitespace
    /// character in `text` — so this matches the guard's exact *expression*
    /// while tolerating the source's line breaks and indentation. A `||`
    /// weakening or a dropped term does not match.
    private static func rangeOfWhitespaceFlexible(
        _ needle: String,
        in text: String,
        range searchRange: Range<String.Index>
    ) -> Range<String.Index>? {
        let tokens = needle.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        var searchStart = searchRange.lowerBound
        while let candidate = text.range(of: first, range: searchStart..<searchRange.upperBound) {
            if let end = whitespaceFlexibleMatchEnd(
                tokens: tokens,
                in: text,
                after: candidate,
                limit: searchRange.upperBound
            ) {
                return candidate.lowerBound..<end
            }
            searchStart = text.index(after: candidate.lowerBound)
        }
        return nil
    }

    /// The end index of a match whose first token is `firstMatch`, or nil when
    /// the remaining tokens do not line up token-for-token.
    private static func whitespaceFlexibleMatchEnd(
        tokens: [String],
        in text: String,
        after firstMatch: Range<String.Index>,
        limit: String.Index
    ) -> String.Index? {
        var upper = firstMatch.upperBound
        for token in tokens.dropFirst() {
            var cursor = upper
            var consumedWhitespace = false
            while cursor < limit, text[cursor].isWhitespace {
                consumedWhitespace = true
                cursor = text.index(after: cursor)
            }
            guard consumedWhitespace else { return nil }
            guard let tokenRange = text.range(of: token, range: cursor..<limit),
                  tokenRange.lowerBound == cursor else { return nil }
            upper = tokenRange.upperBound
        }
        return upper
    }

    // MARK: - Pin mechanics

    /// The exact predicate every upload loop must re-check first.
    private static let uploadLoopGuard =
        "guard isActive, !hasBeenCleaned, let currentSession = libssh2Session, currentSession == session, socket >= 0, atomicSocket.isUsable else {"

    /// The body of `functionAnchor` inside the actor span.
    private static func functionBody(
        _ functionAnchor: String,
        in text: String,
        actorSpan: Range<String.Index>
    ) throws -> Range<String.Index> {
        let anchor = try #require(
            text.range(of: functionAnchor, range: actorSpan),
            "SSHSession must keep the `\(functionAnchor)` function"
        )
        return try bracedBlock(after: anchor, in: text)
    }

    /// Assert that `functionAnchor`'s `loopOccurrence`-th loop opened by
    /// `loopAnchor` contains exactly one of each token and that the loop
    /// body's first statement (after `try Task.checkCancellation()`) is the
    /// exact `expectedGuard`, which precedes the re-entry.
    private static func assertUploadLoopTopGuard(
        functionAnchor: String,
        loopAnchor: String,
        loopOccurrence: Int,
        waitToken: String,
        reentryToken: String,
        in text: String,
        actorSpan: Range<String.Index>
    ) throws {
        let body = try functionBody(functionAnchor, in: text, actorSpan: actorSpan)

        // Positive control: the resolved span is a real retry body, not the
        // SSHClient facade wrapper.
        #expect(
            !text[body].contains("guard !_isAborted"),
            "the resolved span must not be the SSHClient facade wrapper"
        )

        let loopAnchors = occurrences(of: loopAnchor, in: text, range: body)
        #expect(
            loopAnchors.count > loopOccurrence,
            "`\(functionAnchor)` must keep the `\(loopAnchor)` loop at index \(loopOccurrence)"
        )
        let loopAnchorRange = try #require(loopAnchors.dropFirst(loopOccurrence).first)
        let loopOpen = try #require(
            text.range(of: "{", range: loopAnchorRange)?.lowerBound,
            "the `\(loopAnchor)` anchor must end at its opening brace"
        )
        let loopBody = try bracedBlock(openingAt: loopOpen, in: text)

        // Positive controls for the loop slice: the EAGAIN wait and the
        // libssh2 re-entry each live in this loop exactly once.
        #expect(
            occurrences(of: waitToken, in: text, range: loopBody).count == 1,
            "the `\(loopAnchor)` loop body must contain the single `\(waitToken)`"
        )
        let reentries = occurrences(of: reentryToken, in: text, range: loopBody)
        #expect(
            reentries.count == 1,
            "the `\(loopAnchor)` loop body must contain `\(reentryToken)` exactly once; found \(reentries.count)"
        )
        let reentry = try #require(reentries.first)

        // The exact predicate text, not just its individual tokens.
        let guardRange = try #require(
            rangeOfWhitespaceFlexible(uploadLoopGuard, in: text, range: loopBody),
            "the `\(loopAnchor)` loop body must contain the exact guard `\(uploadLoopGuard)`"
        )
        // Placement: the guard is the loop body's first statement — only
        // whitespace and `try Task.checkCancellation()` may precede it.
        let prefix = normalizedWhitespace(text[loopBody.lowerBound..<guardRange.lowerBound])
        #expect(
            prefix.isEmpty || prefix == "try Task.checkCancellation()",
            "the guard must be the loop body's first statement after `try Task.checkCancellation()`; found `\(prefix)` between the loop open and the guard in `\(loopAnchor)`"
        )
        // The guard must precede the re-entry. When it does, the guard body
        // must be the fail-fast throw; when it does not, this pin is already
        // red and only the direction check runs (constructing a descending
        // range would crash the test process instead of failing the pin).
        let guardBeforeReentry = guardRange.lowerBound < reentry.lowerBound
        #expect(
            guardBeforeReentry,
            "the guard must precede `\(reentryToken)` in the `\(loopAnchor)` loop body"
        )
        if guardBeforeReentry {
            let throwRange = try #require(
                text.range(
                    of: "throw SSHError.notConnected",
                    range: guardRange.upperBound..<reentry.lowerBound
                ),
                "the guard in `\(loopAnchor)` must throw `SSHError.notConnected`"
            )
            #expect(
                throwRange.upperBound <= reentry.lowerBound,
                "the guard's throw must precede `\(reentryToken)` in the `\(loopAnchor)` loop body"
            )
        }
    }

    /// Assert that `functionAnchor`'s `loopOccurrence`-th `while true` loop
    /// contains exactly one `reentryToken`, that the loop-top guard is the
    /// exact predicate first statement, and that the guard precedes the
    /// re-entry. For the two `drainChannelOutput` loops the re-entry token
    /// doubles as the positive control (the loops have no wait).
    private static func assertDrainLoopTopGuard(
        functionAnchor: String,
        loopOccurrence: Int,
        reentryToken: String,
        in text: String,
        actorSpan: Range<String.Index>
    ) throws {
        let body = try functionBody(functionAnchor, in: text, actorSpan: actorSpan)
        let loopAnchors = occurrences(of: "while true {", in: text, range: body)
        #expect(
            loopAnchors.count > loopOccurrence,
            "`\(functionAnchor)` must keep the `while true` loop at index \(loopOccurrence)"
        )
        let loopAnchorRange = try #require(loopAnchors.dropFirst(loopOccurrence).first)
        let loopOpen = try #require(
            text.range(of: "{", range: loopAnchorRange)?.lowerBound,
            "the `while true` anchor must end at its opening brace"
        )
        let loopBody = try bracedBlock(openingAt: loopOpen, in: text)

        let reentries = occurrences(of: reentryToken, in: text, range: loopBody)
        #expect(
            reentries.count == 1,
            "the drain loop at index \(loopOccurrence) must contain `\(reentryToken)` exactly once (positive control for the loop slice)"
        )
        let reentry = try #require(reentries.first)

        let guardRange = try #require(
            rangeOfWhitespaceFlexible(uploadLoopGuard, in: text, range: loopBody),
            "the drain loop at index \(loopOccurrence) must contain the exact guard `\(uploadLoopGuard)`"
        )
        let prefix = normalizedWhitespace(text[loopBody.lowerBound..<guardRange.lowerBound])
        #expect(
            prefix.isEmpty || prefix == "try Task.checkCancellation()",
            "the drain guard must be the loop body's first statement after `try Task.checkCancellation()`; found `\(prefix)`"
        )
        let guardBeforeReentry = guardRange.lowerBound < reentry.lowerBound
        #expect(
            guardBeforeReentry,
            "the guard must precede `\(reentryToken)`"
        )
        if guardBeforeReentry {
            let throwRange = try #require(
                text.range(
                    of: "throw SSHError.notConnected",
                    range: guardRange.upperBound..<reentry.lowerBound
                ),
                "the drain guard must throw `SSHError.notConnected`"
            )
            #expect(
                throwRange.upperBound <= reentry.lowerBound,
                "the guard's throw must precede `\(reentryToken)`"
            )
        }
    }

    /// Assert the helper's signature still takes the captured session.
    private static func assertSessionParameter(
        functionAnchor: String,
        in text: String,
        actorSpan: Range<String.Index>
    ) throws {
        let anchor = try #require(
            text.range(of: functionAnchor, range: actorSpan),
            "SSHSession must keep the `\(functionAnchor)` helper"
        )
        let signatureEnd = try #require(
            text.range(of: ") async throws", range: anchor.upperBound..<text.endIndex),
            "the `\(functionAnchor)` signature must close with `) async throws`"
        )
        let signature = text[anchor.lowerBound..<signatureEnd.upperBound]
        #expect(
            signature.contains("session: OpaquePointer"),
            "`\(functionAnchor)` must take the captured `session: OpaquePointer` parameter; the guard's identity check depends on it"
        )
    }

    // MARK: - Pins 1-2: uploadViaSCP

    /// Pin 1: the SCP channel-open retry loop.
    @Test
    func testSCPChannelOpenLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func uploadViaSCP(",
            loopAnchor: "while scpChannel == nil {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_scp_send64(",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 2: the SCP write retry loop.
    @Test
    func testSCPWriteLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func uploadViaSCP(",
            loopAnchor: "while offset < bytes.count {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_write_ex(openedChannel, 0",
            in: text,
            actorSpan: actorSpan
        )
    }

    // MARK: - Pins 3-5: uploadViaExec

    /// Pin 3: the exec channel-open retry loop.
    @Test
    func testExecChannelOpenLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func uploadViaExec(",
            loopAnchor: "while execChannel == nil {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_open_ex(",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 4: the exec startup retry loop.
    @Test
    func testExecStartupLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func uploadViaExec(",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_process_startup(",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 5: the exec write retry loop.
    @Test
    func testExecWriteLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func uploadViaExec(",
            loopAnchor: "while offset < bytes.count {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_write_ex(openedChannel, 0",
            in: text,
            actorSpan: actorSpan
        )
    }

    // MARK: - Pins 6-9: finishUploadChannel's four loops

    /// Pin 6: the send-eof retry loop, and the helper's `session:` parameter.
    @Test
    func testFinishUploadChannelSendEOFLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertSessionParameter(
            functionAnchor: "private func finishUploadChannel(",
            in: text,
            actorSpan: actorSpan
        )
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func finishUploadChannel(",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_send_eof(",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 7: the wait-eof retry loop's top guard.
    @Test
    func testFinishUploadChannelWaitEOFLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func finishUploadChannel(",
            loopAnchor: "while true {",
            loopOccurrence: 1,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_wait_eof(",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 8: the close retry loop.
    @Test
    func testFinishUploadChannelCloseLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func finishUploadChannel(",
            loopAnchor: "while true {",
            loopOccurrence: 2,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_close(channel)",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 9: the wait-closed retry loop.
    @Test
    func testFinishUploadChannelWaitClosedLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertUploadLoopTopGuard(
            functionAnchor: "private func finishUploadChannel(",
            loopAnchor: "while true {",
            loopOccurrence: 3,
            waitToken: "await waitForSocket()",
            reentryToken: "libssh2_channel_wait_closed(",
            in: text,
            actorSpan: actorSpan
        )
    }

    // MARK: - Pin 10: the post-drain re-validation (lens 2 L1)

    /// Pin 10 (lens 2 L1): the wait-eof loop drains output before
    /// `libssh2_channel_wait_eof`, so the loop-top guard does not dominate
    /// that re-entry if the drain ever suspends. The same exact predicate
    /// must appear again between the `drainChannelOutput` call and the
    /// `wait_eof` call. This is the pin the loop-top pins cannot express.
    @Test
    func testFinishUploadChannelRevalidatesAfterTheDrainBeforeWaitEOF() throws {
        let (text, actorSpan) = try Self.slicedSource()
        let body = try Self.functionBody(
            "private func finishUploadChannel(",
            in: text,
            actorSpan: actorSpan
        )
        let loopAnchors = Self.occurrences(of: "while true {", in: text, range: body)
        let loopAnchorRange = try #require(loopAnchors.dropFirst(1).first)
        let loopOpen = try #require(text.range(of: "{", range: loopAnchorRange)?.lowerBound)
        let loopBody = try Self.bracedBlock(openingAt: loopOpen, in: text)

        let drain = try #require(
            text.range(of: "try await drainChannelOutput(", range: loopBody),
            "the wait-eof loop must drain output before waiting for EOF"
        )
        let waitEOF = try #require(
            text.range(of: "libssh2_channel_wait_eof(", range: loopBody),
            "the wait-eof loop must call libssh2_channel_wait_eof"
        )
        #expect(
            drain.upperBound <= waitEOF.lowerBound,
            "the drain must run before the wait-eof call"
        )

        let between = drain.upperBound..<waitEOF.lowerBound
        let guardRange = try #require(
            Self.rangeOfWhitespaceFlexible(Self.uploadLoopGuard, in: text, range: between),
            "the wait-eof loop must re-validate the session with the exact guard between `drainChannelOutput` and `libssh2_channel_wait_eof` (lens 2 L1)"
        )
        let throwRange = try #require(
            text.range(
                of: "throw SSHError.notConnected",
                range: guardRange.upperBound..<waitEOF.lowerBound
            ),
            "the post-drain guard must throw `SSHError.notConnected`"
        )
        #expect(
            throwRange.upperBound <= waitEOF.lowerBound,
            "the post-drain guard's throw must precede the wait-eof call"
        )
    }

    // MARK: - Pins 11-12: drainChannelOutput

    /// Pin 11: the stdout drain loop. It has no wait (it `break`s on
    /// `EAGAIN`/0), so its positive control is the read re-entry token.
    @Test
    func testDrainChannelOutputStdoutLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertSessionParameter(
            functionAnchor: "private func drainChannelOutput(",
            in: text,
            actorSpan: actorSpan
        )
        try Self.assertDrainLoopTopGuard(
            functionAnchor: "private func drainChannelOutput(",
            loopOccurrence: 0,
            reentryToken: "libssh2_channel_read_ex(channel, 0",
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 12: the stderr drain loop.
    @Test
    func testDrainChannelOutputStderrLoopRechecksLivenessAtTheLoopTop() throws {
        let (text, actorSpan) = try Self.slicedSource()
        try Self.assertDrainLoopTopGuard(
            functionAnchor: "private func drainChannelOutput(",
            loopOccurrence: 1,
            reentryToken: "libssh2_channel_read_ex(channel, 1",
            in: text,
            actorSpan: actorSpan
        )
    }
}
