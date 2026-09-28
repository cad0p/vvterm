// SPDX-License-Identifier: MIT
//
//  SSHShellLoopLivenessPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #290: the shell `write(_:to:)` and
//  `resize(cols:rows:pixelSize:for:)` EAGAIN retry loops re-enter libssh2 on a
//  shell channel that `cleanupLibssh2()`'s session free reaps
//  (`abandonAllShellChannels()` empties `shellChannels` without freeing, so
//  the session free is what invalidates the channel). The fix re-checks the
//  captured `ShellChannelState` at the top of every loop body:
//
//      guard isActive, shellChannels[shellId] === state else {
//          throw SSHError.notConnected
//      }
//
//  THE WINDOW IS LATENT, NOT REACHABLE TODAY. `await waitForSocket()` is a
//  same-actor call into a fully synchronous body (`poll(&pfd, 1, 5)`, no
//  `await`/`Task.yield()`), and actor re-entry needs a suspension — so
//  `disconnect()`/`cleanup()` cannot interleave with these loops at the
//  commit that added them. These pins enforce the structural invariant that
//  the issue's acceptance asks for, and they are insurance: adding a
//  suspension to the wait helper or to a loop body would silently reopen the
//  window, and a guard deletion is what these pins catch.
//
//  Why source pins instead of a behavioural test: this target has no
//  SSH-server/libssh2 fixture (`LoopbackTLSServerTestSupport` is TLS-only and
//  `SSHStartupIntegrationTests` is env-gated plain SSH); `shellChannels` is
//  private with no hook; no test calls `libssh2_session_init`/
//  `libssh2_channel_open`; and a synthetic `OpaquePointer` faults inside
//  libssh2 before any assertion can run. The real connect/write/resize path
//  is exercised by the dispatched `teleport-e2e.yml` run
//  (`TeleportServerIntegrationTests.teleportSFTPRoundTripAndShellResize`),
//  which is normal-path regression coverage, not a reproduction of the
//  parked window.
//
//  FORMATTING HEURISTIC, NOT A PROOF: a pin is defeated by an alias
//  (`let ch = state.channel`), a renamed variable, a multi-line call, a
//  guard hoisted into a helper, or a comment-stripped scan that a string
//  literal satisfies. Every pin here is a tripwire for the regression shape,
//  not proof of the discipline; the same-actor/non-suspending reasoning in
//  the fix commit is the proof. Comments are stripped before every scan, so a
//  commented-out guard cannot satisfy an assertion. The `count == 1`
//  assertions deliberately make a duplicated loop red: a new retry loop in
//  this family must extend the pin on purpose.
//

import Foundation
import Testing

@testable import VVTerm

struct SSHShellLoopLivenessPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHShellLoopLivenessPinsTests.swift`).
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
            .deletingLastPathComponent()  // SSHShellLoopLivenessPinsTests.swift
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

    /// Whether `index` falls strictly inside the `block` span (the span
    /// returned by `bracedBlock` excludes the braces themselves).
    private static func isInside(_ block: Range<String.Index>, _ index: String.Index) -> Bool {
        block.lowerBound < index && index < block.upperBound
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

    // MARK: - Pins

    /// Pin 1 (#290): the `SSHSession.write(_:to:)` loop body must re-check
    /// `isActive` and the captured `ShellChannelState` identity at its top,
    /// before the `libssh2_channel_write_ex` call.
    @Test
    func testShellWriteLoopRechecksChannelLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func write(_ data: Data, to shellId: UUID) async throws",
            loopAnchor: "while remaining > 0 {",
            waitToken: "await waitForSocket()",
            reentryTokens: ["libssh2_channel_write_ex("],
            guardTokens: ["isActive", "shellChannels[shellId] === state"],
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 2 (#290): the `SSHSession.resize(cols:rows:pixelSize:for:)` loop
    /// body must re-check `isActive` and the captured `ShellChannelState`
    /// identity at its top, before the
    /// `libssh2_channel_request_pty_size_ex` call.
    @Test
    func testShellResizeLoopRechecksChannelLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func resize(",
            loopAnchor: "while true {",
            waitToken: "await waitForSocket()",
            reentryTokens: ["libssh2_channel_request_pty_size_ex("],
            guardTokens: ["isActive", "shellChannels[shellId] === state"],
            in: text,
            actorSpan: actorSpan
        )
    }

    // MARK: - Pin mechanics

    /// The search span of the `SSHSession` actor: everything after the
    /// `actor SSHSession {` declaration. Eight helper names are duplicated on
    /// `actor SSHClient` earlier in the file (`write` and `resize` included,
    /// and neither is `private`), so resolving an anchor without this slice
    /// binds the facade wrapper — which has no EAGAIN loop — and the pin
    /// cannot fail. Positive control: the `SSHSession` marker resolves.
    private static func sshSessionSpan(in text: String) throws -> Range<String.Index> {
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration"
        )
        return actorAnchor.upperBound..<text.endIndex
    }

    /// Assert that `functionAnchor`'s loop opened by `loopAnchor` contains
    /// exactly one `waitToken` and one of each `reentryTokens`, and that every
    /// `guardTokens` occurrence sits inside that loop body **before** every
    /// re-entry token.
    ///
    /// The function body is resolved after `actor SSHSession {` so the
    /// `SSHClient` facade wrapper of the same name can never satisfy the
    /// scan; a positive control asserts the resolved span is the real body.
    private static func assertLoopTopGuard(
        functionAnchor: String,
        loopAnchor: String,
        waitToken: String,
        reentryTokens: [String],
        guardTokens: [String],
        in text: String,
        actorSpan: Range<String.Index>
    ) throws {
        let anchor = try #require(
            text.range(of: functionAnchor, range: actorSpan),
            "SSHSession must keep the `\(functionAnchor)` helper"
        )
        let functionBody = try bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is a real retry body (it holds
        // the EAGAIN wait and the libssh2 re-entry), not a facade wrapper.
        #expect(
            !text[functionBody].contains("guard !_isAborted"),
            "the resolved span must not be the SSHClient facade wrapper"
        )
        #expect(
            occurrences(of: waitToken, in: text, range: functionBody).count == 1,
            "`\(functionAnchor)` must contain exactly one `\(waitToken)`"
        )
        for reentry in reentryTokens {
            #expect(
                occurrences(of: reentry, in: text, range: functionBody).count == 1,
                "`\(functionAnchor)` must contain exactly one `\(reentry)`"
            )
        }

        // Per-function loop anchor (not a `while true` filter): the loop body
        // is the braced block opened by the anchor, and the anchor must be
        // unique inside the function.
        let loopAnchors = occurrences(of: loopAnchor, in: text, range: functionBody)
        #expect(
            loopAnchors.count == 1,
            "`\(functionAnchor)` must keep exactly one `\(loopAnchor)` loop"
        )
        let loopAnchorRange = try #require(loopAnchors.first)
        let loopOpen = try #require(
            text.range(of: "{", range: loopAnchorRange)?.lowerBound,
            "the `\(loopAnchor)` anchor must end at its opening brace"
        )
        let loopBody = try bracedBlock(openingAt: loopOpen, in: text)

        // The wait belongs to this loop (positive control for the loop slice).
        #expect(
            occurrences(of: waitToken, in: text, range: loopBody).count == 1,
            "the `\(loopAnchor)` loop body must contain the single `\(waitToken)`"
        )

        // Every re-entry the loop can resume into must sit after the guard:
        // the EAGAIN `wait → continue → top` path and any other path back to
        // the libssh2 call go through the loop top (issue #288's L1 defect is
        // the same shape in `listDirectory`).
        for reentry in reentryTokens {
            let inLoop = occurrences(of: reentry, in: text, range: loopBody)
            #expect(
                inLoop.count == 1,
                "the `\(loopAnchor)` loop body must contain `\(reentry)` exactly once"
            )
            let reentryRange = try #require(inLoop.first)
            for guardToken in guardTokens {
                let guards = occurrences(of: guardToken, in: text, range: loopBody)
                #expect(
                    !guards.isEmpty,
                    "the `\(loopAnchor)` loop body must re-check `\(guardToken)` at its top"
                )
                let guardRange = try #require(guards.first)
                #expect(
                    isInside(loopBody, guardRange.lowerBound),
                    "`\(guardToken)` must sit inside the `\(loopAnchor)` loop body"
                )
                #expect(
                    guardRange.lowerBound < reentryRange.lowerBound,
                    "`\(guardToken)` must precede `\(reentry)` in the `\(loopAnchor)` loop body"
                )
            }
        }
    }
}
