// SPDX-License-Identifier: MIT
//
//  SSHFSFTPLoopLivenessPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #288: every SFTP EAGAIN retry loop captures its
//  `sftp` handle / backing `session` before the loop and re-enters libssh2
//  after `await waitForSFTPSocket()` without re-validating them. The fix
//  re-checks the session and the handle at the top of every loop body:
//
//      guard isActive,
//            !hasBeenCleaned,
//            sftp == sftpSession,
//            (sftpSessionIsInner ? innerLibssh2Session : libssh2Session) == session else {
//          throw RemoteFileBrowserError.disconnected
//      }
//
//  and gates the `ensureSFTPSession()` cached fast path on the same liveness.
//
//  THE WINDOW IS LATENT, NOT REACHABLE TODAY. `waitForSFTPSocket()` /
//  `waitForInnerSocket()` / `waitForSocket()` are same-actor calls into fully
//  synchronous bodies (`poll(&pfd, 1, 5)`, no `await`/`Task.yield()`), and
//  actor re-entry needs a suspension — so `disconnect()`/`cleanup()` cannot
//  interleave with these loops at the commit that added them. These pins
//  enforce the structural invariant (and its placement) that the issue's
//  acceptance asks for, and they are insurance: adding a suspension to the
//  wait helper or to a loop body would silently reopen the window, and a
//  guard deletion is what these pins catch.
//
//  Placement is the point, so the pins assert it: the guard must sit at the
//  loop top, before every libssh2 re-entry. `listDirectory` is the reason —
//  it has a second suspension (`await readlink(at:)`) after which the next
//  iteration re-enters `libssh2_sftp_readdir_ex`, so a guard placed only
//  after the EAGAIN wait would miss it. Both re-entry tokens are asserted.
//
//  Why source pins instead of a behavioural test: this target has no
//  SSH-server/libssh2 fixture (`LoopbackTLSServerTestSupport` is TLS-only and
//  `SSHStartupIntegrationTests` is env-gated plain SSH); `sftpSession` /
//  `sftpSessionIsInner` are private with no hook; no test calls
//  `libssh2_sftp_init`; and a synthetic `OpaquePointer` faults inside libssh2
//  before any assertion can run. A pure predicate + matrix test was rejected
//  on purpose: it would test the boolean, not its placement, and placement is
//  the defect (precedent for the extracted-predicate idiom exists in
//  `TeleportSFTPRoutingTests`). The real SFTP path is normal-path-covered by
//  the dispatched `teleport-e2e.yml` run
//  (`TeleportServerIntegrationTests.teleportSFTPRoundTripAndShellResize`) —
//  not a reproduction of the parked window.
//
//  FORMATTING HEURISTIC, NOT A PROOF: a pin is defeated by an alias
//  (`let s = sftp; s == sftpSession`), a renamed variable, a multi-line call,
//  a guard hoisted into a helper, or braces inside a string literal in a
//  walked block. Every pin here is a tripwire for the regression shape, not
//  proof of the discipline; the same-actor/non-suspending reasoning in the
//  fix commit is the proof. Comments are stripped before every scan, so a
//  commented-out guard cannot satisfy an assertion. The per-function
//  `count == 1` assertions deliberately make a duplicated loop or re-entry
//  red: a new retry loop in this family must extend the pin on purpose.
//
//  NOT PINNED HERE: the conditional handle closes (the four
//  `defer { if isActive, !hasBeenCleaned, sftp == sftpSession { … } }` owners)
//  and the `ensureSFTPSession()` init-loop top guards are asserted through the
//  same guard tokens as the loops above; the conditional-close *shape* is
//  deliberately left to review (the plan's pin count is loops + fast path).
//

import Foundation
import Testing

@testable import VVTerm

struct SSHFSFTPLoopLivenessPinsTests {

    // MARK: - Fixtures

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSH/SSHFSFTPLoopLivenessPinsTests.swift`).
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
            .deletingLastPathComponent()  // SSHFSFTPLoopLivenessPinsTests.swift
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

    // MARK: - Pins: the twelve SFTP retry loops

    /// Pin 1 (#288): `listDirectory` — the loop-top guard must precede BOTH
    /// re-entry tokens. The `await readlink(at:)` suspension is the second
    /// one (its resume loops back into `libssh2_sftp_readdir_ex`), so an
    /// after-the-wait-only guard is the defect this asserts against.
    @Test
    func testListDirectoryLoopGuardsBothReentryPaths() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func listDirectory(at path: String, maxEntries: Int? = nil) async throws -> [RemoteFileEntry]",
            loopAnchor: "while entries.count < limit {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_readdir_ex(", "await readlink(at: entryPath)"],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 2 (#288): `readFile`.
    @Test
    func testReadFileLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func readFile(at path: String, maxBytes: Int, offset: UInt64 = 0) async throws -> Data",
            loopAnchor: "while data.count < maxBytes {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_read("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 3 (#288): `downloadFile`.
    @Test
    func testDownloadFileLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func downloadFile(at path: String, to localURL: URL) async throws",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_read("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 4 (#288): `writeFile`.
    @Test
    func testWriteFileLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func writeFile(_ data: Data, to path: String, permissions: Int32 = 0o644) async throws",
            loopAnchor: "while totalBytesWritten < data.count {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_write("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 5 (#288): `fileSystemStatus`.
    @Test
    func testFileSystemStatusLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func fileSystemStatus(at path: String) async throws -> RemoteFileFilesystemStatus",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_statvfs("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 6 (#288): `setPermissions`.
    @Test
    func testSetPermissionsLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "func setPermissions(at path: String, permissions: UInt32) async throws",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_stat_ex("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 7 (#288): the `ensureSFTPSession()` inner-session init loop.
    @Test
    func testEnsureSFTPSessionInnerInitLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func ensureSFTPSession() async throws -> OpaquePointer",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForInnerSocket()",
            reentryTokens: ["libssh2_sftp_init(inner)"],
            guardTokens: ["isActive", "!hasBeenCleaned", "innerLibssh2Session == inner"],
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 8 (#288): the `ensureSFTPSession()` outer-session init loop.
    @Test
    func testEnsureSFTPSessionOuterInitLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func ensureSFTPSession() async throws -> OpaquePointer",
            loopAnchor: "while true {",
            loopOccurrence: 1,
            waitToken: "await waitForSocket()",
            reentryTokens: ["libssh2_sftp_init(session)"],
            guardTokens: ["isActive", "!hasBeenCleaned", "libssh2Session == session"],
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 9 (#288): `openSFTPHandle` (serves `listDirectory`'s directory
    /// handle and `readFile`/`downloadFile`/`writeFile`'s file handles).
    @Test
    func testOpenSFTPHandleLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func openSFTPHandle(",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_open_ex("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 10 (#288): `performSFTPMutation` (serves `createDirectory`,
    /// `renameItem`, `deleteFile`, `deleteDirectory`).
    @Test
    func testPerformSFTPMutationLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func performSFTPMutation(",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["mutation(sftp, pathPtr, pathLength)"],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 11 (#288): `stat(at:statType:)` (serves `stat`/`lstat`).
    @Test
    func testStatLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func stat(at path: String, statType: Int32) async throws -> RemoteFileEntry",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_stat_ex("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    /// Pin 12 (#288): `readSymlinkTarget` (serves `readlink` and
    /// `resolveHomeDirectory`).
    @Test
    func testReadSymlinkTargetLoopRechecksLivenessAtTheLoopTop() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)
        try Self.assertLoopTopGuard(
            functionAnchor: "private func readSymlinkTarget(",
            loopAnchor: "while true {",
            loopOccurrence: 0,
            waitToken: "await waitForSFTPSocket()",
            reentryTokens: ["libssh2_sftp_symlink_ex("],
            guardTokens: Self.fullSFTPGuardTokens,
            in: text,
            actorSpan: actorSpan
        )
    }

    // MARK: - Pin: the cached fast path

    /// Pin 13 (#288): the `ensureSFTPSession()` cached fast path must gate the
    /// `return sftpSession` on session liveness. This is a BEHAVIOUR CHANGE
    /// (documented in the PR body): in the deferred-teardown window the
    /// handle is still allocated but the transport is going down, so the call
    /// now fails fast with `.disconnected` instead of handing it out.
    @Test
    func testEnsureSFTPSessionCachedFastPathIsGatedOnLiveness() throws {
        let text = Self.strippingComments(try source("VVTerm/Core/SSH/SSHClient.swift"))
        let actorSpan = try Self.sshSessionSpan(in: text)

        let anchor = try #require(
            text.range(
                of: "private func ensureSFTPSession() async throws -> OpaquePointer",
                range: actorSpan
            ),
            "SSHSession must keep ensureSFTPSession()"
        )
        let functionBody = try Self.bracedBlock(after: anchor, in: text)

        // Brace-less anchor: `bracedBlock(after:)` binds the first `{` after
        // the anchor, so an anchor that already contains the fast path's `{`
        // would bind the guard's nested `else` block instead (test lens T1).
        let fastPathAnchor = try #require(
            text.range(of: "if let sftpSession", range: functionBody),
            "ensureSFTPSession must keep its `if let sftpSession` fast path"
        )
        let fastPathBlock = try Self.bracedBlock(after: fastPathAnchor, in: text)

        // Positive control: the resolved block is the fast path (it returns
        // the cached handle), not an unrelated `if let` in the function.
        #expect(
            text[fastPathBlock].contains("return sftpSession"),
            "the resolved span must be the cached fast-path block"
        )

        let firstWhile = try #require(
            text.range(of: "while true {", range: functionBody),
            "ensureSFTPSession must keep its init loop"
        )
        #expect(
            fastPathBlock.upperBound <= firstWhile.lowerBound,
            "the resolved fast-path block must precede the init loop"
        )

        // The fast path is the first `return sftpSession` in the function.
        let returns = Self.occurrences(of: "return sftpSession", in: text, range: functionBody)
        let fastPathReturn = try #require(returns.first)
        #expect(
            Self.isInside(fastPathBlock, fastPathReturn.lowerBound),
            "the first `return sftpSession` must be the gated fast path"
        )

        for token in [
            "isActive",
            "!hasBeenCleaned",
            "sftpSessionIsInner ? innerLibssh2Session : libssh2Session"
        ] {
            let hits = Self.occurrences(of: token, in: text, range: fastPathBlock)
            #expect(
                !hits.isEmpty,
                "the cached fast path must gate `return sftpSession` on `\(token)`"
            )
            let first = try #require(hits.first)
            #expect(
                first.lowerBound < fastPathReturn.lowerBound,
                "`\(token)` must precede the fast-path `return sftpSession`"
            )
        }
    }

    // MARK: - Pin mechanics

    /// The guard tokens every handle-based SFTP loop must re-check.
    private static let fullSFTPGuardTokens = [
        "isActive",
        "!hasBeenCleaned",
        "sftp == sftpSession",
        "sftpSessionIsInner ? innerLibssh2Session : libssh2Session"
    ]

    /// The search span of the `SSHSession` actor: everything after the
    /// `actor SSHSession {` declaration. Several helper names are duplicated
    /// on `actor SSHClient` earlier in the file, so resolving an anchor
    /// without this slice can bind a facade wrapper. Positive control: the
    /// `SSHSession` marker resolves.
    private static func sshSessionSpan(in text: String) throws -> Range<String.Index> {
        let actorAnchor = try #require(
            text.range(of: "actor SSHSession {"),
            "SSHClient.swift must keep the `actor SSHSession {` declaration"
        )
        return actorAnchor.upperBound..<text.endIndex
    }

    /// Assert that `functionAnchor`'s `loopOccurrence`-th loop opened by
    /// `loopAnchor` contains exactly one `waitToken` and one of each
    /// `reentryTokens`, and that every `guardTokens` occurrence sits inside
    /// that loop body **before** every re-entry token.
    private static func assertLoopTopGuard(
        functionAnchor: String,
        loopAnchor: String,
        loopOccurrence: Int,
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
        let functionBody = try Self.bracedBlock(after: anchor, in: text)

        // Positive control: the resolved span is a real retry body (it holds
        // the EAGAIN wait and the libssh2 re-entry), not a facade wrapper.
        #expect(
            !text[functionBody].contains("guard !_isAborted"),
            "the resolved span must not be the SSHClient facade wrapper"
        )
        #expect(
            Self.occurrences(of: waitToken, in: text, range: functionBody).count == 1,
            "`\(functionAnchor)` must contain exactly one `\(waitToken)`"
        )
        for reentry in reentryTokens {
            #expect(
                Self.occurrences(of: reentry, in: text, range: functionBody).count == 1,
                "`\(functionAnchor)` must contain exactly one `\(reentry)`"
            )
        }

        // Per-function loop anchor (not a `while true` filter): the loop body
        // is the braced block opened by the anchor.
        let loopAnchors = Self.occurrences(of: loopAnchor, in: text, range: functionBody)
        #expect(
            loopAnchors.count > loopOccurrence,
            "`\(functionAnchor)` must keep the `\(loopAnchor)` loop at index \(loopOccurrence)"
        )
        let loopAnchorRange = try #require(loopAnchors.dropFirst(loopOccurrence).first)
        let loopOpen = try #require(
            text.range(of: "{", range: loopAnchorRange)?.lowerBound,
            "the `\(loopAnchor)` anchor must end at its opening brace"
        )
        let loopBody = try Self.bracedBlock(openingAt: loopOpen, in: text)

        // The wait belongs to this loop (positive control for the loop slice).
        #expect(
            Self.occurrences(of: waitToken, in: text, range: loopBody).count == 1,
            "the `\(loopAnchor)` loop body must contain the single `\(waitToken)`"
        )

        // Every re-entry the loop can resume into must sit after the guard:
        // the EAGAIN `wait -> continue -> top` path and any other path back
        // to the libssh2 call go through the loop top (the `listDirectory`
        // `await readlink` resume is the second such path).
        for reentry in reentryTokens {
            let inLoop = Self.occurrences(of: reentry, in: text, range: loopBody)
            #expect(
                inLoop.count == 1,
                "the `\(loopAnchor)` loop body must contain `\(reentry)` exactly once"
            )
            let reentryRange = try #require(inLoop.first)
            for guardToken in guardTokens {
                let guards = Self.occurrences(of: guardToken, in: text, range: loopBody)
                #expect(
                    !guards.isEmpty,
                    "the `\(loopAnchor)` loop body must re-check `\(guardToken)` at its top"
                )
                let guardRange = try #require(guards.first)
                #expect(
                    Self.isInside(loopBody, guardRange.lowerBound),
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
