// SPDX-License-Identifier: MIT
//
//  SSHUploadChannelFreePinsTests.swift
//  VVTermTests
//
//  Source pins for the reachable upload-channel double free (issue #291,
//  Finding A).
//
//  THE DEFECT: `finishUploadChannel` used to free its channel and return the
//  exit status; `uploadViaExec` throws on a non-zero exit status *inside* the
//  same `do`, so its `catch` closed and freed the channel again. A failing
//  `cat > <path>` (missing parent / unwritable directory / directory path)
//  is enough — no race and no disconnect. At the pinned libssh2 commit the
//  second `libssh2_channel_free` is not an idempotent no-op: `ssh2_channel_free`
//  writes `channel->free_state` (channel.c:2615, :2630), unconditionally frees
//  `channel->exit_signal` (:2632), frees the channel-type/packet pointers
//  (:2650-2664), does `ssh2_list_remove(&channel->node)` (:2654) and finally
//  `SSH2_FREE(session, channel)` (:2698) — pointer writes and frees driven by
//  whatever now occupies the block. Writes-and-frees heap corruption / invalid
//  free, not just a stale read.
//
//  THE FIX (pinned here): the helper never frees; each caller is the single
//  free owner on every exit path — free once after the helper returns on the
//  success path, clear the caller's outer optional so the catch cannot free a
//  second time, and make the catch's close+free liveness-conditional so a
//  future guard throw (which means the session free already reaped the
//  channel) does not relocate the use-after-free into the catch. The skipped
//  catch free leaves the channel to `libssh2_session_free` — a bounded,
//  deliberate leak, the same trade the SFTP conditional defers make.
//
//  Why source pins instead of a behavioural test: this target has no
//  SSH-server/libssh2 fixture (`LoopbackTLSServerTestSupport` is TLS-only and
//  `SSHStartupIntegrationTests` is env-gated plain SSH); `scpChannel` /
//  `execChannel` are function locals with no hook; no test calls
//  `libssh2_session_init`/`libssh2_scp_send64`; and a synthetic
//  `OpaquePointer` faults inside libssh2 before any assertion can run. The
//  reachable defect is covered end-to-end by the hardened failing-exec leg
//  (ASan/`MallocScribble`) and by these pins; the runtime detector is what
//  makes the double free loud.
//
//  FORMATTING HEURISTIC, NOT A PROOF: a pin is defeated by an alias, a
//  multi-line call, a renamed variable, an unguarded free moved into another
//  helper, or braces inside a string literal in a walked block. Comments are
//  stripped before every scan, so a commented-out call cannot satisfy (or
//  trip) an assertion. The `count == 1` assertions deliberately make a *new*
//  free site red: a second owner of these channels must update the pin on
//  purpose.
//

import Foundation
import Testing

@testable import VVTerm

struct SSHUploadChannelFreePinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHUploadChannelFreePinsTests.swift`).
    private static func repositoryRoot() -> URL {
        // Counterfactual hook: the guard-sensitivity runs point this at a
        // mutated tree to prove the pins fail there. Never set in CI. NOTE:
        // the variable must actually reach the test process — the
        // `TEST_RUNNER_` form reaches it under `xcodebuild test` (measured
        // and documented in the merged #288/#290 pin suites); a plain env var
        // is inert, and `test-without-building -xctestrun` does not strip the
        // prefix.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHUploadChannelFreePinsTests.swift
            .deletingLastPathComponent()  // SSH/
            .deletingLastPathComponent()  // VVTermTests/
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    // MARK: - Source helpers

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so slice anchors still resolve. String
    /// contents are copied verbatim. Duplicated from the merged pin suites
    /// (`SSHProxyChannelFreePinsTests`, `SSHFSFTPLoopLivenessPinsTests`) so
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

    /// The body span of the first brace-delimited block after `anchor`.
    ///
    /// The anchor must be **brace-less** for the intended block to be the one
    /// it opens: `bracedBlock` binds the first `{` after the anchor, so an
    /// anchor that already contains the opening brace skips the intended
    /// block and binds its first nested block instead.
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

    /// The whitespace-normalized form of `text`: every run of whitespace
    /// collapses to a single space (empty for an all-whitespace span).
    private static func normalizedWhitespace(_ text: Substring) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The range of the first whitespace-flexible occurrence of `needle`
    /// within `text[searchRange]`. `needle` is split on single spaces, and
    /// each piece must occur in order, separated by at least one whitespace
    /// character in `text` — so this matches the condition's exact
    /// *expression* while tolerating the source's line breaks. A dropped
    /// liveness term does not match.
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

    /// The search span of the `SSHSession` actor: everything after the
    /// `actor SSHSession {` declaration. Helper names are duplicated on
    /// `actor SSHClient` earlier in the file, so resolving an anchor without
    /// this slice can bind a facade wrapper. Positive control: the marker
    /// resolves.
    private static func sshSessionSpan(in text: String) throws -> Range<String.Index> {
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration"
        )
        return actorAnchor.upperBound..<text.endIndex
    }

    // MARK: - Slice helpers

    /// The `SSHSession` actor span of the production source.
    private static func slicedSource() throws -> (text: String, actorSpan: Range<String.Index>) {
        let text = Self.strippingComments(try Self.source("VVTerm/Core/SSH/SSHClient.swift"))
        return (text, try Self.sshSessionSpan(in: text))
    }

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

    /// The `do { … }` span that follows `varAnchor` in a caller.
    private static func doBlock(
        afterVarAnchor varAnchor: String,
        in text: String,
        functionBody: Range<String.Index>
    ) throws -> Range<String.Index> {
        let anchor = try #require(
            text.range(of: varAnchor, range: functionBody),
            "the caller must keep `\(varAnchor)`"
        )
        return try bracedBlock(after: anchor, in: text)
    }

    /// The `catch { … }` span of a caller.
    private static func catchBlock(
        in text: String,
        functionBody: Range<String.Index>
    ) throws -> Range<String.Index> {
        let anchors = occurrences(of: "catch {", in: text, range: functionBody)
        #expect(
            anchors.count == 1,
            "the caller must keep exactly one `catch {`; found \(anchors.count)"
        )
        let anchor = try #require(anchors.first, "the caller must keep its catch block")
        let open = text.index(before: anchor.upperBound)
        #expect(text[open] == "{", "the resolved catch anchor must end at its opening brace")
        return try bracedBlock(openingAt: open, in: text)
    }

    // MARK: - Pin A1: the helper does not free

    /// Pin A1 (#291 Finding A): `finishUploadChannel`'s body must contain
    /// **zero** `libssh2_channel_free` calls. Restoring the helper's free
    /// (the original defect shape) reddens this pin.
    @Test
    func testFinishUploadChannelDoesNotFreeItsChannel() throws {
        let (text, actorSpan) = try Self.slicedSource()
        let body = try Self.functionBody(
            "private func finishUploadChannel(",
            in: text,
            actorSpan: actorSpan
        )

        // Positive control (A6): the slice is the helper's close/finish body,
        // not a caller or an unrelated function.
        let positiveControls = [
            "libssh2_channel_send_eof(channel)",
            "libssh2_channel_wait_eof(channel)",
            "libssh2_channel_close(channel)",
            "libssh2_channel_wait_closed(channel)",
            "libssh2_channel_get_exit_status(channel)"
        ]
        for token in positiveControls {
            #expect(
                text[body].contains(token),
                "the resolved finishUploadChannel span must contain `\(token)`"
            )
        }
        #expect(
            text[body].contains("return exitStatus"),
            "the resolved finishUploadChannel span must return the exit status"
        )

        let frees = Self.occurrences(of: "libssh2_channel_free(", in: text, range: body)
        #expect(
            frees.isEmpty,
            "finishUploadChannel must not free its channel: each caller is the single free owner on every exit path (issue #291 Finding A)"
        )
    }

    // MARK: - Pin A2: the SCP caller frees exactly once

    /// Pin A2 (#291 Finding A): `uploadViaSCP`'s `do` body must contain
    /// exactly one `libssh2_channel_free`, positioned after the
    /// `finishUploadChannel` call. Deleting the success-path free reddens it.
    @Test
    func testSCPCallerFreesTheChannelExactlyOnceAfterTheHelper() throws {
        let (text, actorSpan) = try Self.slicedSource()
        let body = try Self.functionBody(
            "private func uploadViaSCP(",
            in: text,
            actorSpan: actorSpan
        )
        let doBody = try Self.doBlock(
            afterVarAnchor: "var scpChannel: OpaquePointer?",
            in: text,
            functionBody: body
        )

        // Positive controls (A6): the resolved do span is the SCP success
        // path, not the exec caller or a nested block.
        #expect(
            text[doBody].contains("libssh2_scp_send64("),
            "the resolved do span must be the SCP open/write/finish path"
        )
        #expect(
            text[doBody].contains("libssh2_channel_write_ex(openedChannel"),
            "the resolved do span must contain the SCP write loop"
        )

        let helperCalls = Self.occurrences(of: "finishUploadChannel(openedChannel", in: text, range: doBody)
        #expect(
            helperCalls.count == 1,
            "uploadViaSCP must call `finishUploadChannel(openedChannel, …)` exactly once"
        )
        let helperCall = try #require(helperCalls.first)

        let frees = Self.occurrences(of: "libssh2_channel_free(", in: text, range: doBody)
        #expect(
            frees.count == 1,
            "uploadViaSCP's success path must free the channel exactly once; found \(frees.count)"
        )
        let free = try #require(frees.first)
        #expect(
            helperCall.upperBound <= free.lowerBound,
            "the SCP success-path free must run after `finishUploadChannel` returns"
        )
    }

    // MARK: - Pin A3: the exec caller frees exactly once, before the status throw

    /// Pin A3 (#291 Finding A): `uploadViaExec`'s `do` body must contain
    /// exactly one `libssh2_channel_free`, positioned after the
    /// `finishUploadChannel` call and before the `guard exitStatus == 0`
    /// throw. Reordering the free below the throw (or deleting it) reddens
    /// this pin.
    @Test
    func testExecCallerFreesTheChannelExactlyOnceBeforeTheExitStatusThrow() throws {
        let (text, actorSpan) = try Self.slicedSource()
        let body = try Self.functionBody(
            "private func uploadViaExec(",
            in: text,
            actorSpan: actorSpan
        )
        let doBody = try Self.doBlock(
            afterVarAnchor: "var execChannel: OpaquePointer?",
            in: text,
            functionBody: body
        )

        // Positive controls (A6): the resolved do span is the exec path.
        #expect(
            text[doBody].contains("libssh2_channel_open_ex("),
            "the resolved do span must be the exec open/startup/write/finish path"
        )
        #expect(
            text[doBody].contains("libssh2_channel_process_startup("),
            "the resolved do span must contain the exec startup loop"
        )

        let helperCalls = Self.occurrences(
            of: "finishUploadChannel(openedChannel",
            in: text,
            range: doBody
        )
        #expect(
            helperCalls.count == 1,
            "uploadViaExec must call `finishUploadChannel(openedChannel, …)` exactly once"
        )
        let helperCall = try #require(helperCalls.first)

        let guards = Self.occurrences(of: "guard exitStatus == 0 else", in: text, range: doBody)
        let guardRange = try #require(
            guards.first,
            "uploadViaExec must keep its `guard exitStatus == 0 else` throw"
        )
        #expect(
            guards.count == 1,
            "uploadViaExec must keep exactly one exit-status guard"
        )

        let frees = Self.occurrences(of: "libssh2_channel_free(", in: text, range: doBody)
        #expect(
            frees.count == 1,
            "uploadViaExec's success path must free the channel exactly once; found \(frees.count)"
        )
        let free = try #require(frees.first)
        #expect(
            helperCall.upperBound <= free.lowerBound,
            "the exec success-path free must run after `finishUploadChannel` returns"
        )
        #expect(
            free.upperBound <= guardRange.lowerBound,
            "the exec success-path free must run before the exit-status throw, so the throw cannot double-free"
        )
    }

    // MARK: - Pin A4: the callers clear their outer optional

    /// Pin A4 (#291 Finding A): each caller must clear its outer optional
    /// (`scpChannel = nil` / `execChannel = nil`) after the success-path free
    /// and before the exit-status throw / end of `do`. Deleting the clear
    /// reintroduces the double free through the catch.
    @Test
    func testCallersClearTheOuterOptionalAfterTheSuccessFree() throws {
        let (text, actorSpan) = try Self.slicedSource()

        let scpBody = try Self.functionBody(
            "private func uploadViaSCP(",
            in: text,
            actorSpan: actorSpan
        )
        let scpDo = try Self.doBlock(
            afterVarAnchor: "var scpChannel: OpaquePointer?",
            in: text,
            functionBody: scpBody
        )
        let scpFree = try #require(
            Self.occurrences(of: "libssh2_channel_free(openedChannel)", in: text, range: scpDo).first,
            "uploadViaSCP must free `openedChannel` on the success path"
        )
        let scpClears = Self.occurrences(of: "scpChannel = nil", in: text, range: scpDo)
        #expect(
            scpClears.count == 1,
            "uploadViaSCP must clear `scpChannel` exactly once after the success free; found \(scpClears.count)"
        )
        let scpClear = try #require(scpClears.first)
        #expect(
            scpFree.upperBound <= scpClear.lowerBound,
            "`scpChannel = nil` must run after the success free so the catch cannot free again"
        )

        let execBody = try Self.functionBody(
            "private func uploadViaExec(",
            in: text,
            actorSpan: actorSpan
        )
        let execDo = try Self.doBlock(
            afterVarAnchor: "var execChannel: OpaquePointer?",
            in: text,
            functionBody: execBody
        )
        let execFree = try #require(
            Self.occurrences(of: "libssh2_channel_free(openedChannel)", in: text, range: execDo).first,
            "uploadViaExec must free `openedChannel` on the success path"
        )
        let execGuard = try #require(
            Self.occurrences(of: "guard exitStatus == 0 else", in: text, range: execDo).first,
            "uploadViaExec must keep its exit-status guard"
        )
        let execClears = Self.occurrences(of: "execChannel = nil", in: text, range: execDo)
        #expect(
            execClears.count == 1,
            "uploadViaExec must clear `execChannel` exactly once after the success free; found \(execClears.count)"
        )
        let execClear = try #require(execClears.first)
        #expect(
            execFree.upperBound <= execClear.lowerBound,
            "`execChannel = nil` must run after the success free so the catch cannot free again"
        )
        #expect(
            execClear.upperBound <= execGuard.lowerBound,
            "`execChannel = nil` must run before the exit-status throw"
        )
    }

    // MARK: - Pin A5: the catches are liveness-conditional

    /// Pin A5 (#291, lens 1 S1): each caller's catch `close`+`free` pair must
    /// sit inside an `if` whose exact condition is
    /// `if let <channel>, isActive, !hasBeenCleaned, libssh2Session == session`.
    /// Reverting the catch to unconditional (or deleting its free) reddens
    /// this pin.
    @Test
    func testSCPCatchFreesOnlyWhileTheSessionIsLive() throws {
        try Self.assertCatchIsLivenessConditional(
            functionAnchor: "private func uploadViaSCP(",
            outerChannelName: "scpChannel"
        )
    }

    @Test
    func testExecCatchFreesOnlyWhileTheSessionIsLive() throws {
        try Self.assertCatchIsLivenessConditional(
            functionAnchor: "private func uploadViaExec(",
            outerChannelName: "execChannel"
        )
    }

    private static func assertCatchIsLivenessConditional(
        functionAnchor: String,
        outerChannelName: String
    ) throws {
        let (text, actorSpan) = try Self.slicedSource()
        let body = try functionBody(functionAnchor, in: text, actorSpan: actorSpan)
        let catchBody = try catchBlock(in: text, functionBody: body)

        // Positive control (A6): the slice is the caller's catch, not the do.
        #expect(
            text[catchBody].contains("throw error"),
            "the resolved catch span must rethrow the original error"
        )

        let closes = occurrences(of: "libssh2_channel_close(\(outerChannelName))", in: text, range: catchBody)
        let frees = occurrences(of: "libssh2_channel_free(\(outerChannelName))", in: text, range: catchBody)
        #expect(
            closes.count == 1,
            "the catch must close `\(outerChannelName)` exactly once; found \(closes.count)"
        )
        #expect(
            frees.count == 1,
            "the catch must free `\(outerChannelName)` exactly once; found \(frees.count)"
        )
        let close = try #require(closes.first)
        let free = try #require(frees.first)
        #expect(
            close.upperBound <= free.lowerBound,
            "the catch must close `\(outerChannelName)` before freeing it"
        )

        let condition = try #require(
            rangeOfWhitespaceFlexible(
                "if let \(outerChannelName), isActive, !hasBeenCleaned, libssh2Session == session",
                in: text,
                range: catchBody
            ),
            "the catch must gate its close+free on `if let \(outerChannelName), isActive, !hasBeenCleaned, libssh2Session == session` (lens 1 S1)"
        )
        let ifBody = try bracedBlock(after: condition, in: text)
        #expect(
            isInside(ifBody, close.lowerBound),
            "the catch close must run inside the liveness-conditional `if`"
        )
        #expect(
            isInside(ifBody, free.lowerBound),
            "the catch free must run inside the liveness-conditional `if`"
        )
        #expect(
            condition.lowerBound < close.lowerBound && condition.lowerBound < free.lowerBound,
            "the liveness condition must precede both the close and the free"
        )
        // The condition is the catch body's first statement.
        let prefix = normalizedWhitespace(text[catchBody.lowerBound..<condition.lowerBound])
        #expect(
            prefix.isEmpty,
            "the liveness-conditional `if` must be the catch body's first statement; found `\(prefix)` before it"
        )
    }

    // MARK: - Pin A6: anchor drift positive control

    /// Pin A6 (#291): the suite's anchors must all resolve against the
    /// production source, so a rename or a moved slice reddens the suite
    /// loudly instead of silently skipping. This is the positive-control pin
    /// for A1-A5.
    @Test
    func testUploadFamilyPinAnchorsResolve() throws {
        let (text, actorSpan) = try Self.slicedSource()
        let helper = try Self.functionBody(
            "private func finishUploadChannel(",
            in: text,
            actorSpan: actorSpan
        )
        let scp = try Self.functionBody(
            "private func uploadViaSCP(",
            in: text,
            actorSpan: actorSpan
        )
        let exec = try Self.functionBody(
            "private func uploadViaExec(",
            in: text,
            actorSpan: actorSpan
        )
        #expect(!text[helper].isEmpty, "the finishUploadChannel slice must be non-empty")
        #expect(!text[scp].isEmpty, "the uploadViaSCP slice must be non-empty")
        #expect(!text[exec].isEmpty, "the uploadViaExec slice must be non-empty")

        // The helper call is the interface between the two halves of this
        // suite: both callers resolve it in their `do` spans.
        #expect(
            text[scp].contains("finishUploadChannel(openedChannel"),
            "uploadViaSCP must keep its helper call"
        )
        #expect(
            text[exec].contains("finishUploadChannel(openedChannel"),
            "uploadViaExec must keep its helper call"
        )
        // Both callers keep exactly one success free and one catch free.
        for (name, body) in [("uploadViaSCP", scp), ("uploadViaExec", exec)] {
            #expect(
                Self.occurrences(of: "libssh2_channel_free(", in: text, range: body).count == 2,
                "\(name) must own exactly two frees: one success-path free and one catch free"
            )
        }
    }
}
