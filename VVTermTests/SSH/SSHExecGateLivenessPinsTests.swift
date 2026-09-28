// SPDX-License-Identifier: MIT
//
//  SSHExecGateLivenessPinsTests.swift
//  VVTermTests
//
//  Source pins for commit `3e695028` ("gate the outer exec channel opens on
//  `isActive`"): `ensureExecChannelReady`'s outer guard and `execute()`'s
//  outer branch must re-check `isActive` before the exec path can re-enter
//  `libssh2_channel_open_ex` on a session whose free is pending (#286's
//  deferred-teardown window: `invalidateTransport()` nils `ioTask` while
//  `libssh2Session` stays non-nil, so `startIOLoop()` can start a fresh,
//  uncancelled loop that reaches the channel open). The inner twin already
//  re-checks `innerSocket`/`innerAtomicSocket`/`!hasBeenCleaned`; the outer
//  path has no socketpair, so `isActive` is the session-free gate there.
//
//  These two gates carry the same class as the #288/#290 loops and are pinned
//  with the same recipe (see `SSHShellLoopLivenessPinsTests` /
//  `SSHFSFTPLoopLivenessPinsTests`), as a third self-contained family file so
//  commit 3's revert stays independent of the first two.
//
//  `ensureExecChannelReady` reaches the literal `libssh2_channel_open_ex(` in
//  its own body, so its pin asserts the exact gate precedes that token. In
//  `execute()` the channel open is one function away — the call chain is
//  `startIOLoop()` (which starts the loop) then
//  `enqueueExecRequest(command, isInner: false)` (which the loop drains into
//  `ensureExecChannelReady`) — so its pin asserts the exact gate precedes
//  `startIOLoop()` and that `startIOLoop()` precedes the outer enqueue.
//
//  WHAT THESE PINS ASSERT (and what they do not see). Each pin
//  whitespace-normalizes the source and matches the gate's EXACT predicate
//  text, then asserts the gate precedes the re-entry token. A logic mutation
//  that preserves every individual token (`&&` -> `||`, `,` -> `||`, a
//  dropped `isActive`) does not match the exact predicate and goes red. It is
//  still a tripwire, not a proof: a suspension added elsewhere, a re-entry
//  the pin does not list, or any behavioural change outside the pinned text
//  is invisible. A renamed variable makes the exact-text match red — a
//  deliberate tripwire firing that forces the author to re-affirm the pin,
//  not a silent pass. Comments are stripped before every scan, so a
//  commented-out gate cannot satisfy an assertion. The `count == 1`
//  assertions deliberately make a duplicated gate or re-entry red.
//

import Foundation
import Testing

@testable import VVTerm

struct SSHExecGateLivenessPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHExecGateLivenessPinsTests.swift`).
    private func repositoryRoot() -> URL {
        // Counterfactual hook: the guard-sensitivity runs point this at a
        // mutated tree to prove the pins fail there. Never set in CI. NOTE:
        // the variable must actually reach the test process. Measured on this
        // runner (2026-09-28, iOS Simulator destination): a plain env var is
        // inert (a mutated root → all pins green), while exporting
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into
        // xcodebuild's own environment reaches the test process (the mutated
        // pin goes red at its assert); the same token passed as a
        // command-line build setting did not reach it here. So use the
        // `TEST_RUNNER_` env form, or hand-mutate the worktree and restore it.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHExecGateLivenessPinsTests.swift
            .deletingLastPathComponent()  // SSH/
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

    /// The range of the first whitespace-flexible occurrence of `needle`
    /// within `text[searchRange]`. `needle` is split on single spaces, and
    /// each piece must occur in order, separated by at least one whitespace
    /// character in `text` — so this matches the gate's exact *expression*
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

    // MARK: - Pins

    /// Pin 1 (commit `3e695028`): `ensureExecChannelReady`'s outer gate must
    /// re-check `isActive` before its `libssh2_channel_open_ex` re-entry.
    @Test
    func testEnsureExecChannelReadyGatesTheOuterChannelOpenOnIsActive() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)

        let anchor = try #require(
            text.range(
                of: "private func ensureExecChannelReady(_ request: ExecRequest) async -> Bool",
                range: actorSpan
            ),
            "SSHSession must keep ensureExecChannelReady(_:)"
        )
        let functionBody = try Self.bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is the real helper (it holds
        // exactly one channel open), not a facade wrapper.
        let opens = Self.occurrences(of: "libssh2_channel_open_ex(", in: text, range: functionBody)
        #expect(
            opens.count == 1,
            "ensureExecChannelReady must contain exactly one `libssh2_channel_open_ex(`"
        )
        let openRange = try #require(opens.first)

        let guardRange = try #require(
            Self.rangeOfWhitespaceFlexible(
                "guard isActive, let session = libssh2Session else {",
                in: text,
                range: functionBody
            ),
            "ensureExecChannelReady must keep the exact outer gate `guard isActive, let session = libssh2Session else {`"
        )
        #expect(
            guardRange.lowerBound < openRange.lowerBound,
            "the `isActive` gate must precede `libssh2_channel_open_ex(` in ensureExecChannelReady"
        )
    }

    /// Pin 2 (commit `3e695028`): `execute()`'s outer branch must re-check
    /// `isActive` before it starts the outer io loop that reaches
    /// `ensureExecChannelReady`'s channel open.
    @Test
    func testExecuteOuterBranchGatesTheExecPathOnIsActive() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)

        let anchor = try #require(
            text.range(
                of: "func execute(_ command: String) async throws -> String",
                range: actorSpan
            ),
            "SSHSession must keep its `execute(_:)` helper"
        )
        let functionBody = try Self.bracedBlock(after: anchor, in: text)

        let loopStarts = Self.occurrences(of: "startIOLoop()", in: text, range: functionBody)
        #expect(
            loopStarts.count == 1,
            "execute() must contain exactly one `startIOLoop()`"
        )
        let loopStartRange = try #require(loopStarts.first)

        let guardRange = try #require(
            Self.rangeOfWhitespaceFlexible(
                "guard isActive, libssh2Session != nil else {",
                in: text,
                range: functionBody
            ),
            "execute() must keep the exact outer gate `guard isActive, libssh2Session != nil else {`"
        )
        #expect(
            guardRange.lowerBound < loopStartRange.lowerBound,
            "the `isActive` gate must precede `startIOLoop()` in execute()"
        )

        // The guarded start must precede the outer enqueue — the call the io
        // loop drains into `ensureExecChannelReady`'s channel open.
        let enqueues = Self.occurrences(
            of: "enqueueExecRequest(command, isInner: false)",
            in: text,
            range: functionBody
        )
        #expect(
            enqueues.count == 1,
            "execute() must contain exactly one outer `enqueueExecRequest(command, isInner: false)`"
        )
        let enqueueRange = try #require(enqueues.first)
        #expect(
            loopStartRange.lowerBound < enqueueRange.lowerBound,
            "`startIOLoop()` must precede the outer `enqueueExecRequest(command, isInner: false)`"
        )
    }

    // MARK: - Pin mechanics

    /// The search span of the `SSHSession` actor: everything after the
    /// `actor SSHSession {` declaration. `execute` is duplicated on
    /// `actor SSHClient` earlier in the file, so resolving an anchor without
    /// this slice binds the facade wrapper. Positive control: the
    /// `SSHSession` marker resolves.
    private static func sshSessionSpan(in text: String) throws -> Range<String.Index> {
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration"
        )
        return actorAnchor.upperBound..<text.endIndex
    }
}
