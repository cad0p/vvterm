// SPDX-License-Identifier: MIT
//
//  SSHProxyChannelFreePinsTests.swift
//  VVTermTests
//
//  Source pins for issue #283: the outer proxy-subsystem channel free in
//  `SSHSession.cleanupLibssh2()` must take `outerSessionMutex` and must run
//  after `cancelPumpSync()` flips the pump's cancel token.
//
//  Why a source pin instead of a behavioural test: this target has no
//  SSH-server/libssh2 fixture (`LoopbackTLSServerTestSupport` is TLS-only and
//  `SSHStartupIntegrationTests` is env-gated plain SSH); no test calls
//  `libssh2_session_init`/`libssh2_channel_open`; `proxySubsystemChannel` is
//  private with no hook; `SSHSession.init(teleportSessionMutex:)` accepts a
//  fake mutex but nil private state never reaches the free; and
//  `makeForChannel` hardcodes libssh2 on an `OpaquePointer`, so a synthetic
//  pointer faults inside libssh2 before any assertion can run. The pump's
//  mutual exclusion is covered behaviourally by
//  `SSHProxySubsystemTransportTests.pumpSerializesChannelReadAndWriteThroughSharedMutex`;
//  what that suite cannot reach is the private teardown. The real
//  connect/teardown path is exercised by the dispatched `teleport-e2e.yml`
//  run.
//
//  FORMATTING HEURISTIC, NOT A PROOF: a pin is defeated by an alias
//  (`let ch = proxyChannel; libssh2_channel_free(ch)`), a multi-line call, a
//  renamed variable, or braces inside a string literal in a walked block.
//  Every pin here is a tripwire for the regression shape, not proof of the
//  discipline; the mutex/token reasoning in the fix commit is the proof.
//  Comments are stripped before every scan, so a commented-out call cannot
//  satisfy (or trip) an assertion; a call inside a string literal still can.
//  The file-wide `count == 1` asserts deliberately make a *new* close/free
//  site red: a second owner of this channel must update the pin on purpose.
//

import Foundation
import Testing

@testable import VVTerm

struct SSHProxyChannelFreePinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHProxyChannelFreePinsTests.swift`).
    private func repositoryRoot() -> URL {
        // Counterfactual hook: the guard-sensitivity runs point this at a
        // mutated tree to prove the pins fail there. Never set in CI. NOTE:
        // the variable must actually reach the test process. Exporting it into
        // `xcodebuild`'s environment does (measured 2026-09-28: a nonexistent
        // root fails the reads; a swapped root goes red at the order assert).
        // A `TEST_RUNNER_`-prefixed *build setting* does not reach the
        // simulator test process here (same swapped root stayed green), so use
        // the environment form, or hand-mutate the worktree and restore it.
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHProxyChannelFreePinsTests.swift
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
    /// it opens: `bracedBlock` binds the first `{` after the anchor, so an
    /// anchor that already contains the opening brace skips the intended
    /// block and binds its first nested block instead (test lens T1). A
    /// mis-slice cannot pass vacuously: an absent block fails the `#require`
    /// here, and the containment asserts it feeds fail when a pinned token
    /// sits outside.
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

    /// Pin 1: inside `SSHSession.cleanupLibssh2()` the `if let proxyChannel`
    /// block must close/free the channel **inside** its
    /// `outerSessionMutex.withLock` span, and the pump cancel
    /// (`cancelPumpSync()`) must precede that block.
    ///
    /// Without the mutex the free can land while a bridge-pump read/write is
    /// in flight; without the cancel first, a closure that acquires the mutex
    /// after the free passes its token guard and calls libssh2 on the freed
    /// channel. Both are use-after-frees of a native channel.
    @Test
    func testProxyChannelFreeIsSerializedThroughTheOuterSessionMutex() throws {
        // One comment-stripped copy of the whole file: the function body, the
        // if-let block, the lock span, and the file-wide call scan all resolve
        // against this same `String`, so every `String.Index` comparison below
        // is valid (never compare indices across differently-sliced strings).
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))

        let bodyStart = try #require(
            text.range(of: "private func cleanupLibssh2()"),
            "SSHClient.swift must keep SSHSession.cleanupLibssh2()"
        )
        let bodyEnd = text.range(
            of: "private func ",
            range: bodyStart.upperBound..<text.endIndex
        )?.lowerBound ?? text.endIndex
        let body = bodyStart.lowerBound..<bodyEnd

        // Brace-less anchor: `bracedBlock(after:)` binds the first `{` after
        // the anchor, so an anchor that already contains the `{` would bind
        // the if-let block's first nested block (the lock body) instead.
        let ifLetAnchor = try #require(
            text.range(of: "if let proxyChannel = proxySubsystemChannel", range: body),
            "cleanupLibssh2 must still guard the proxy-subsystem channel free"
        )
        let ifLetBlock = try Self.bracedBlock(after: ifLetAnchor, in: text)

        // Positive control: the resolved span is the channel-free block, not
        // the outer-session free below it.
        #expect(
            text[ifLetBlock].contains("proxySubsystemChannel = nil"),
            "the resolved if-let span must be the proxy-subsystem channel block"
        )
        #expect(
            !text[ifLetBlock].contains("libssh2_session_free"),
            "the resolved if-let span must not be the outer-session free"
        )

        let lockAnchor = try #require(
            text.range(of: "outerSessionMutex.withLock", range: ifLetBlock),
            "the proxy-subsystem channel free must be serialized through outerSessionMutex"
        )
        let lockBlock = try Self.bracedBlock(after: lockAnchor, in: text)

        let closeCalls = Self.occurrences(of: "libssh2_channel_close(proxyChannel)", in: text)
        let freeCalls = Self.occurrences(of: "libssh2_channel_free(proxyChannel)", in: text)
        #expect(
            closeCalls.count == 1,
            "exactly one libssh2_channel_close(proxyChannel) in SSHClient.swift"
        )
        #expect(
            freeCalls.count == 1,
            "exactly one libssh2_channel_free(proxyChannel) in SSHClient.swift"
        )

        let close = try #require(closeCalls.first)
        let free = try #require(freeCalls.first)
        #expect(
            Self.isInside(lockBlock, close.lowerBound),
            "libssh2_channel_close(proxyChannel) must run inside outerSessionMutex.withLock"
        )
        #expect(
            Self.isInside(lockBlock, free.lowerBound),
            "libssh2_channel_free(proxyChannel) must run inside outerSessionMutex.withLock"
        )

        // Separate in-lock counts: containment alone passes if a third call
        // (a leaked duplicate) already sits inside the lock.
        #expect(
            Self.occurrences(of: "libssh2_channel_close(proxyChannel)", in: text, range: lockBlock).count == 1,
            "exactly one libssh2_channel_close(proxyChannel) inside the lock span"
        )
        #expect(
            Self.occurrences(of: "libssh2_channel_free(proxyChannel)", in: text, range: lockBlock).count == 1,
            "exactly one libssh2_channel_free(proxyChannel) inside the lock span"
        )

        // Ordering inside the lock: `close` before `free`. Freeing first makes
        // the subsequent close a deterministic use-after-free, and no other
        // assert here distinguishes the two orders.
        #expect(
            close.upperBound <= free.lowerBound,
            "libssh2_channel_close(proxyChannel) must precede libssh2_channel_free(proxyChannel)"
        )

        // Ordering: without the token flip first, a pump closure that acquires
        // the mutex after the free passes its token guard and calls libssh2 on
        // the freed channel — a prompt reorder is a UAF.
        let transportGuard = try #require(
            text.range(of: "if let innerTransport = innerTransport", range: body),
            "cleanupLibssh2 must guard the bridge-pump cancel with the transport binding"
        )
        let cancel = try #require(
            text.range(of: "innerTransport.cancelPumpSync()", range: body),
            "cleanupLibssh2 must call innerTransport.cancelPumpSync()"
        )
        #expect(
            transportGuard.lowerBound < ifLetAnchor.lowerBound,
            "the innerTransport cancel guard must appear before the proxy-subsystem channel free"
        )
        #expect(
            cancel.upperBound <= ifLetAnchor.lowerBound,
            "innerTransport.cancelPumpSync() must run before the proxy-subsystem channel free"
        )
    }

    /// Pin 2: `TeleportAgentForwardingService.makeForSession`'s `closeChannel`
    /// closure is the precedent this fix matches — both channel calls must sit
    /// inside its `mutex.withLock` span. The file has three `mutex.withLock`
    /// spans (read, write, close), so the search is scoped to the close
    /// closure body resolved from its own signature; an unscoped search would
    /// bind the read closure's lock and pass vacuously.
    @Test
    func testAgentChannelFreeKeepsTheSameDiscipline() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Teleport/Infrastructure/TeleportAgentForwarding.swift")
        )

        let signature = try #require(
            text.range(of: "closeChannel: { channel in"),
            "TeleportAgentForwardingService.makeForSession must keep the closeChannel closure"
        )
        let closureOpen = try #require(
            text.range(of: "{", range: signature),
            "the closeChannel closure must open a brace"
        )
        let closureBody = try Self.bracedBlock(openingAt: closureOpen.lowerBound, in: text)

        let lockAnchor = try #require(
            text.range(of: "mutex.withLock", range: closureBody),
            "the agent closeChannel closure must take the session mutex"
        )
        let lockBlock = try Self.bracedBlock(after: lockAnchor, in: text)

        let closeCalls = Self.occurrences(of: "libssh2_channel_close(channel)", in: text)
        let freeCalls = Self.occurrences(of: "libssh2_channel_free(channel)", in: text)
        #expect(
            closeCalls.count == 1,
            "exactly one libssh2_channel_close(channel) in TeleportAgentForwarding.swift"
        )
        #expect(
            freeCalls.count == 1,
            "exactly one libssh2_channel_free(channel) in TeleportAgentForwarding.swift"
        )

        let close = try #require(closeCalls.first)
        let free = try #require(freeCalls.first)
        #expect(
            Self.isInside(lockBlock, close.lowerBound),
            "the agent channel close must run inside its mutex.withLock span"
        )
        #expect(
            Self.isInside(lockBlock, free.lowerBound),
            "the agent channel free must run inside its mutex.withLock span"
        )
        #expect(
            close.upperBound <= free.lowerBound,
            "the agent channel close must precede its free"
        )
    }

    /// Pin 3: the pump's production `channelRead`/`channelWrite` closures must
    /// re-check `cancelToken.isCancelled` **inside** the same
    /// `outerSessionMutex.withLock` span as the libssh2 call. Hoisting the
    /// guard above the lock keeps pins 1–2 green while reopening the UAF: the
    /// check passes, the free wins the mutex, and the call lands on the freed
    /// channel.
    @Test
    func testPumpTokenCheckSharesTheMutualExclusionSpan() throws {
        let text = Self.strippingComments(
            try source("VVTerm/Features/Teleport/Infrastructure/SSHProxySubsystemTransport.swift")
        )

        try Self.assertGuardSharesTheLockWithCall(
            signature: "channelRead: { buf, maxLen in",
            libssh2Call: "libssh2_channel_read_ex",
            in: text
        )
        try Self.assertGuardSharesTheLockWithCall(
            signature: "channelWrite: { buf, len in",
            libssh2Call: "libssh2_channel_write_ex",
            in: text
        )
    }

    /// Assert the closure opened by `signature` calls `libssh2Call` exactly
    /// once and re-checks `!cancelToken.isCancelled` exactly once, both
    /// strictly inside the same `outerSessionMutex.withLock` span.
    private static func assertGuardSharesTheLockWithCall(
        signature: String,
        libssh2Call: String,
        in text: String
    ) throws {
        let signatureRange = try #require(
            text.range(of: signature),
            "SSHProxySubsystemTransport.makeForChannel must keep the `\(signature)` closure"
        )
        let closureOpen = try #require(
            text.range(of: "{", range: signatureRange),
            "the `\(signature)` closure must open a brace"
        )
        let closureBody = try bracedBlock(openingAt: closureOpen.lowerBound, in: text)

        let lockAnchor = try #require(
            text.range(of: "outerSessionMutex.withLock", range: closureBody),
            "`\(signature)` must take outerSessionMutex"
        )
        let lockBlock = try bracedBlock(after: lockAnchor, in: text)

        let guards = occurrences(of: "!cancelToken.isCancelled", in: text, range: closureBody)
        let calls = occurrences(of: libssh2Call, in: text, range: closureBody)
        #expect(
            guards.count == 1,
            "`\(signature)` must re-check the cancel token exactly once"
        )
        #expect(
            calls.count == 1,
            "`\(signature)` must call \(libssh2Call) exactly once"
        )

        let guardRange = try #require(guards.first)
        let call = try #require(calls.first)
        #expect(
            isInside(lockBlock, guardRange.lowerBound),
            "the cancel-token guard must sit inside the same outerSessionMutex span as \(libssh2Call)"
        )
        #expect(
            isInside(lockBlock, call.lowerBound),
            "\(libssh2Call) must sit inside the outerSessionMutex span"
        )
    }
}
