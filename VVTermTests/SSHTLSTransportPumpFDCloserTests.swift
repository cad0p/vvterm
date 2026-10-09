// SPDX-License-Identifier: MIT
//
//  SSHTLSTransportPumpFDCloserTests.swift
//  VVTermTests
//
//  Regression coverage for the single-owner close of the `SSHTLSTransport`
//  pump end (issue #234) and for the shutdown/release split that closes the
//  fd-reuse window around it (issue #237).
//
//  #234: the pump end of the socketpair was closed from six racing paths.
//  A repeated `close(2)` is not harmless — if the process has reused that
//  descriptor number for an unrelated file, the close lands on the wrong file
//  and its next read fails with `EBADF` (observed in the extracted package's
//  parallel CI). All paths now route through the shared `PumpFDCloser`.
//
//  #237: `runPump` used to close the pump fd as soon as *one* loop exited,
//  while the sibling was only cancelled, not joined. A `read`/`write` could
//  then start on the descriptor number after `close(2)` freed it (read →
//  unrelated bytes forwarded to the server; write → corrupts an unrelated
//  file). `PumpFDCloser` is now a lock-serialized `open → shutDown → closed`
//  machine: `shutdownOnce` wakes the sibling without freeing the number,
//  `runPump` joins both loops, and only then does `closeOnce` release it. The
//  source pins at the bottom of this file keep that ordering from regressing
//  for the host proxy twin (`SSHProxySubsystemTransport.swift`), which the
//  package does not carry; the package owns the TLS-transport pins.
//
//  XCTest (the host target also runs Swift Testing): this is the XCTest
//  counterpart of the package's suite, adapted to the host types (the
//  `PumpFDCloser` + `makeSocketPair` behavioural cases stay host-side because
//  the host proxy transport owns its own closer). XCTest is
//  required for the SIGPIPE cases so `continueAfterFailure = false` halts
//  before the signalling write; a Swift Testing `#expect` would record a
//  failure and then raise SIGPIPE, killing the test host.
//

#if canImport(Network)
import Darwin
import Foundation
import XCTest
import os
@testable import VVTerm

final class SSHTLSTransportPumpFDCloserTests: XCTestCase {

    /// The guard releases the descriptor on the first close, and every later
    /// close is a no-op. The second half is the part that matters: the
    /// descriptor number is reused (forced here with `dup2`) before the
    /// repeat closes, so a guard without the once-flag would close the
    /// unrelated file that now owns that number.
    func testPumpFDCloserClosesTheDescriptorExactlyOnce() throws {
        var fds: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            // Without this guard a failed socketpair leaves `fds == [0, 0]` and
            // the closes below would shut the test host's stdin.
            throw XCTSkip("socketpair unavailable (errno \(Darwin.errno))")
        }
        let libssh2FD = fds[0]
        let pumpFD = fds[1]
        // Registered immediately, before the closer can free `pumpFD` and
        // `dup2` can reuse it: a crash between creation and the old late
        // registration would have leaked the number (the `F_GETFD` guard
        // skips it once the closer has closed it, and closes it when the
        // reuse below succeeded).
        addDescriptorTeardown([libssh2FD, pumpFD])

        let closer = PumpFDCloser()
        closer.closeOnce(pumpFD)

        // The first close must actually close the descriptor.
        XCTAssertEqual(
            Darwin.fcntl(pumpFD, F_GETFD),
            -1,
            "the first close must actually close the descriptor"
        )

        // Force the freed descriptor number to be reused for an unrelated
        // file, reproducing the fd-reuse window the once-flag protects.
        let unrelated = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(unrelated, 0)
        XCTAssertEqual(
            Darwin.dup2(unrelated, pumpFD),
            pumpFD,
            "the test needs to force reuse of the freed descriptor number"
        )
        if unrelated != pumpFD { Darwin.close(unrelated) }

        // Every later close must be a no-op: the reused descriptor must
        // survive (a second close here would close /dev/null's descriptor).
        closer.closeOnce(pumpFD)
        closer.closeOnce(pumpFD)
        XCTAssertNotEqual(
            Darwin.fcntl(pumpFD, F_GETFD),
            -1,
            "a repeat close landed on the reused descriptor number"
        )
    }

    /// A source-level tripwire over the host proxy transport that owns a pump
    /// end: no line in `SSHProxySubsystemTransport.swift` may contain both
    /// `Darwin.close(` and `pumpFD` — every close of the pump end must route
    /// through `PumpFDCloser`. This is a FORMATTING HEURISTIC, NOT A PROOF: it
    /// is defeated by an unqualified `close(pumpFD)`, a multi-line call, or
    /// `let fd = pair.pumpFD; Darwin.close(fd)`. The behavioural tests above
    /// are the real gate; this only catches the obvious reintroduction. The
    /// package owns the equivalent pin for `SSHTLSTransport.swift`.
    func testPumpEndIsClosedOnlyThroughTheSingleOwnerGuard() throws {
        let relativePaths = [
            "VVTerm/Features/Teleport/Infrastructure/SSHProxySubsystemTransport.swift",
        ]
        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repositoryRoot().appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let rawPumpCloses = source
                .components(separatedBy: .newlines)
                .filter { $0.contains("Darwin.close(") && $0.contains("pumpFD") }
            XCTAssertTrue(
                rawPumpCloses.isEmpty,
                "\(relativePath): the pump fd must only be closed by PumpFDCloser; found: \(rawPumpCloses)"
            )
        }
    }

    /// `PumpFDCloser.closeOnce` shuts the descriptor down before closing it, so
    /// a `write` racing that close gets `EPIPE` — and without `SO_NOSIGPIPE`
    /// the kernel raises `SIGPIPE`, which terminates the app host (observed as
    /// `Test crashed with signal pipe.`). Both socketpair ends must carry the
    /// option.
    func testSocketPairSuppressesSIGPIPEOnBothEnds() throws {
        // A failed assertion must stop the test before the write below.
        // `continueAfterFailure` defaults to true, so without this a missing
        // option would be recorded and the test would still reach the
        // signalling write — failing as a host crash instead of a clean
        // assertion.
        continueAfterFailure = false
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        addDescriptorTeardown([pair.libssh2FD, pair.pumpFD])

        // Asserted first: if the option is missing, fail here rather than reach
        // the write below, which would raise SIGPIPE and kill the test host.
        for (name, fd) in [("libssh2FD", pair.libssh2FD), ("pumpFD", pair.pumpFD)] {
            var value: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            XCTAssertEqual(
                Darwin.getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &size),
                0,
                "getsockopt(SO_NOSIGPIPE) failed on \(name)"
            )
            XCTAssertEqual(value, 1, "SO_NOSIGPIPE must be set on \(name)")
        }

        // The behaviour the option buys. `closeOnce` shuts the descriptor down
        // before closing it, so a pump write racing the close (`writeAllToPumpFD`
        // writes to this same fd) must return `EPIPE` rather than raise
        // `SIGPIPE`. Measured without the option, this exact write is killed by
        // signal 13.
        XCTAssertEqual(Darwin.shutdown(pair.pumpFD, SHUT_WR), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.write(pair.pumpFD, &byte, 1), -1)
        XCTAssertEqual(Darwin.errno, EPIPE)
    }

    // MARK: - issue #237: shutdown / release split

    /// `shutdownOnce` wakes an in-flight read (EOF) and write (EPIPE) without
    /// freeing the descriptor number — that is what lets `runPump` join its
    /// loops before the release. The fd is built by `makeSocketPair` (NOT a
    /// raw `socketpair`): `SO_NOSIGPIPE` must be set or the post-shutdown
    /// write raises `SIGPIPE` and kills the test host.
    func testShutdownOnceWakesWithoutFreeingTheDescriptor() throws {
        // A failed assertion must stop this test before the write below.
        continueAfterFailure = false
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        // This test only shuts `pumpFD` down; the teardown's `F_GETFD` guard
        // skips a number that was freed and reused.
        addDescriptorTeardown([pair.libssh2FD, pair.pumpFD])

        // Asserted first: if the option is missing, fail here rather than
        // reach the write, which would raise SIGPIPE and kill the test host.
        var option: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(Darwin.getsockopt(pair.pumpFD, SOL_SOCKET, SO_NOSIGPIPE, &option, &size), 0)
        XCTAssertEqual(option, 1, "SO_NOSIGPIPE must be set on pumpFD before the write")

        let closer = PumpFDCloser()
        XCTAssertEqual(closer.stateForTesting, .open)

        closer.shutdownOnce(pair.pumpFD)
        XCTAssertEqual(closer.stateForTesting, .shutDown)

        // A racing read sees EOF and a racing write sees EPIPE, while the
        // number stays owned. The write is kept last (it is the
        // SIGPIPE-risking syscall).
        var readBack: UInt8 = 0
        XCTAssertEqual(Darwin.read(pair.pumpFD, &readBack, 1), 0, "a racing read must see EOF")
        XCTAssertNotEqual(
            Darwin.fcntl(pair.pumpFD, F_GETFD),
            -1,
            "shutdown(2) must not free the descriptor number"
        )
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.write(pair.pumpFD, &byte, 1), -1)
        XCTAssertEqual(Darwin.errno, EPIPE)
    }

    /// A shutdown followed by a close still closes exactly once.
    func testCloseOnceAfterShutdownClosesExactlyOnce() throws {
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        // Registered before the first close/reuse below: a crash between
        // creation and the old late registration would have leaked `pumpFD`.
        addDescriptorTeardown([pair.libssh2FD, pair.pumpFD])

        let closer = PumpFDCloser()
        closer.shutdownOnce(pair.pumpFD)
        XCTAssertEqual(closer.stateForTesting, .shutDown)
        XCTAssertNotEqual(Darwin.fcntl(pair.pumpFD, F_GETFD), -1)

        closer.closeOnce(pair.pumpFD)
        XCTAssertEqual(closer.stateForTesting, .closed)
        XCTAssertEqual(Darwin.fcntl(pair.pumpFD, F_GETFD), -1, "closeOnce must release the number")

        // ...and the release happens exactly once: force reuse with `dup2`,
        // then a repeat close must be a no-op rather than landing on the
        // unrelated file.
        let unrelated = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(unrelated, 0)
        XCTAssertEqual(Darwin.dup2(unrelated, pair.pumpFD), pair.pumpFD)
        if unrelated != pair.pumpFD { Darwin.close(unrelated) }

        closer.closeOnce(pair.pumpFD)
        XCTAssertNotEqual(
            Darwin.fcntl(pair.pumpFD, F_GETFD),
            -1,
            "a repeat close landed on the reused descriptor number"
        )
    }

    /// Once closed, `.closed` is terminal: a later `shutdownOnce` on the same
    /// (now reused) number must not touch it. The assertion is the reused
    /// fd's **writability**, not merely "still open": `shutdown(2)` does not
    /// change `F_GETFD`, and queued bytes on the peer drain before EOF, so a
    /// stale `shutdown(SHUT_RDWR)` would still be caught only by the write
    /// returning `EPIPE`.
    func testShutdownOnceAfterCloseOnceDoesNotTouchAReusedDescriptor() throws {
        continueAfterFailure = false
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        // Registered at creation: a throw from the second `makeSocketPair`
        // must not leak this pair (the `F_GETFD` guard skips a number the
        // closer freed in the meantime).
        addDescriptorTeardown([pair.libssh2FD, pair.pumpFD])

        // The unrelated descriptor the freed number is reused for is a real
        // socket, so a stale wake is observable on the wire. It comes from
        // `makeSocketPair` so `SO_NOSIGPIPE` is set (the write below must not
        // raise SIGPIPE even under a mutation).
        let unrelated = try SSHProxySubsystemTransport.makeSocketPair()
        // `pair.pumpFD` stays covered by the first teardown: by then the
        // closer has freed it and `dup2` has reused it for `unrelated.pumpFD`,
        // so that guard closes whichever number currently owns it. This block
        // runs first (teardowns are LIFO) and the guards make a double-close
        // of a number impossible.
        addDescriptorTeardown([unrelated.libssh2FD, unrelated.pumpFD])

        let closer = PumpFDCloser()
        closer.closeOnce(pair.pumpFD)
        XCTAssertEqual(closer.stateForTesting, .closed)
        XCTAssertEqual(Darwin.fcntl(pair.pumpFD, F_GETFD), -1)

        // Force reuse of the freed number for the unrelated socket.
        XCTAssertEqual(Darwin.dup2(unrelated.pumpFD, pair.pumpFD), pair.pumpFD)

        closer.shutdownOnce(pair.pumpFD)

        // The reused descriptor must still be fully functional: a stale
        // `shutdown(SHUT_RDWR)` on the number would have shut this socket
        // down, so this write would fail and the peer's read would see EOF.
        var byte: UInt8 = 0x5A
        XCTAssertEqual(Darwin.write(pair.pumpFD, &byte, 1), 1, "the reused descriptor was shut down")
        var readBack: UInt8 = 0
        XCTAssertEqual(Darwin.read(unrelated.libssh2FD, &readBack, 1), 1)
        XCTAssertEqual(readBack, 0x5A)
        XCTAssertNotEqual(Darwin.fcntl(pair.pumpFD, F_GETFD), -1)
    }

    /// The socketpair-buffer variant of the wake test, pinning the measured
    /// `shutdown(2)` behaviour that makes the pre-join wake a **prompt** exit:
    /// with the buffer full to EAGAIN, the next write returns `EPIPE` (not
    /// `EAGAIN`) and the pump end reads EOF — while `fcntl(F_GETFD)` still
    /// succeeds. `read(pair.pumpFD)` is named deliberately: a read on
    /// `libssh2FD` would return queued bytes first.
    func testShutdownUnblocksAFullBufferWrite() throws {
        continueAfterFailure = false
        let pair = try SSHProxySubsystemTransport.makeSocketPair()
        addDescriptorTeardown([pair.libssh2FD, pair.pumpFD])

        // Fill the pump end's send buffer (the peer never reads).
        let chunk = Data(repeating: 0x41, count: 64 * 1024)
        var filled = 0
        while true {
            let n = chunk.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(pair.pumpFD, base, raw.count)
            }
            if n > 0 { filled += n; continue }
            XCTAssertEqual(Darwin.errno, EAGAIN, "the socketpair buffer must be full")
            break
        }
        XCTAssertGreaterThan(filled, 0)

        let closer = PumpFDCloser()
        closer.shutdownOnce(pair.pumpFD)
        XCTAssertEqual(closer.stateForTesting, .shutDown)

        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.write(pair.pumpFD, &byte, 1), -1)
        XCTAssertEqual(Darwin.errno, EPIPE)
        var readBack: UInt8 = 0
        XCTAssertEqual(Darwin.read(pair.pumpFD, &readBack, 1), 0, "read(pair.pumpFD) must be EOF")
        XCTAssertNotEqual(
            Darwin.fcntl(pair.pumpFD, F_GETFD),
            -1,
            "shutdown(2) must not free the descriptor number"
        )
    }

    // MARK: - issue #237: source pins
    /// Host-only pins for the proxy twin (`SSHProxySubsystemTransport.swift`):
    /// the package has no equivalent file, and its pump wakes differently —
    /// no `NWConnection`, so `runPump` flips the channel `PumpCancelToken`
    /// before the join. Lexical heuristics, same caveats as the behavioural
    /// pins above (comment tokens are stripped before the scans;
    /// string-literal tokens can still satisfy them).
    func testProxyPumpSourcePinsHoldAfterTheSplit() throws {
        let source = try proxySource()
        // Line-level scans run on the comment-stripped copy, as in the TLS
        // pin: a commented-out token cannot satisfy them and the line numbers
        // are unchanged.
        let codeLines = Self.strippingComments(source).components(separatedBy: .newlines)

        // The closer stays declared exactly once, in this file (the package
        // owns its own copy in `SSHTLSTransport.swift`).
        XCTAssertEqual(
            codeLines.filter { $0.contains("class PumpFDCloser") }.count,
            1,
            "PumpFDCloser must be declared exactly once, in the proxy transport file"
        )

        // (a) Every closeOnce( call site lives in runPump — the proxy has no
        // handshake-failure path. `cancelPumpSync()` must only wake.
        let closeOnceLines = codeLines.enumerated().filter { _, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return line.contains("closeOnce(")
        }
        XCTAssertEqual(
            closeOnceLines.count,
            2,
            "expected one closeOnce( call site plus the declaration; re-derive this pin"
        )
        var enclosingFunctions: [String] = []
        for (index, line) in closeOnceLines where !line.contains("func closeOnce(") {
            let enclosing = try XCTUnwrap(
                Self.enclosingFunctionName(before: index, in: codeLines),
                "no enclosing function for the closeOnce( call on line \(index + 1)"
            )
            enclosingFunctions.append(enclosing)
        }
        XCTAssertEqual(
            Set(enclosingFunctions),
            ["runPump"],
            "closeOnce( may only be reached from runPump after its join"
        )

        let cancelStart = try XCTUnwrap(
            source.range(of: "nonisolated func cancelPumpSync()"),
            "cancelPumpSync() declaration not found"
        )
        let cancelTail = source[cancelStart.lowerBound...]
        let cancelEnd = try XCTUnwrap(
            cancelTail.range(of: "\n    // MARK: - Pump internals"),
            "cancelPumpSync() slice end not found"
        )
        let cancelCode = Self.strippingComments(String(cancelTail[cancelTail.startIndex..<cancelEnd.lowerBound]))
        XCTAssertFalse(
            cancelCode.contains("closeOnce("),
            "cancelPumpSync() must only wake the pump end; the release belongs to runPump after the join"
        )
        XCTAssertTrue(
            cancelCode.contains("shutdownOnce("),
            "cancelPumpSync() must wake the pump end so the pump loops can exit"
        )

        // (b) runPump's body: token flip + wake before the join, release after
        // it, and no actor capture in the detached pump-start closure.
        let runPumpStart = try XCTUnwrap(
            source.range(of: "nonisolated private static func runPump("),
            "runPump must keep the pinned static declaration"
        )
        let runPumpTail = source[runPumpStart.lowerBound...]
        let runPumpEnd = try XCTUnwrap(
            runPumpTail.range(of: "\n    nonisolated private static func pumpChannelToFD("),
            "runPump body end not found"
        )
        let runPumpCode = Self.strippingComments(String(runPumpTail[runPumpTail.startIndex..<runPumpEnd.lowerBound]))
        let joinAnchor = try XCTUnwrap(
            runPumpCode.range(of: "await group.waitForAll()"),
            "runPump must join both loops before releasing the descriptor"
        )
        let beforeJoin = runPumpCode[runPumpCode.startIndex..<joinAnchor.lowerBound]
        let afterJoin = runPumpCode[joinAnchor.upperBound...]
        XCTAssertTrue(beforeJoin.contains("shutdownOnce("), "the pre-join wake must stay in runPump")
        XCTAssertTrue(
            beforeJoin.contains("cancelToken?.cancel()"),
            "the proxy pump must flip the channel token before the join, or a loop parked in the synchronous closure cannot exit"
        )
        XCTAssertFalse(beforeJoin.contains("closeOnce("), "closeOnce( must not run before the join")
        XCTAssertTrue(afterJoin.contains("closeOnce("), "runPump must release the descriptor after the join")

        let pumpStart = try XCTUnwrap(
            source.range(of: "Task.detached(priority: .userInitiated)"),
            "the pump must start in a detached task"
        )
        let pumpStartTail = source[pumpStart.lowerBound...]
        let pumpStartEnd = try XCTUnwrap(
            pumpStartTail.range(of: "pumpTask = task"),
            "pump-start closure slice end not found"
        )
        let pumpStartCode = Self.strippingComments(String(pumpStartTail[pumpStartTail.startIndex..<pumpStartEnd.lowerBound]))
        XCTAssertFalse(
            pumpStartCode.contains("weak self"),
            "the pump body must not capture the actor weakly"
        )
        XCTAssertFalse(
            pumpStartCode.contains("guard let self"),
            "the pump body must not be able to skip the release when the actor is gone"
        )

        // (c) The closer's syscalls run inside `state.withLock`; none after
        // the lock's closing brace (the sequential behavioural tests cannot
        // observe that preemption window).
        let shutdownBody = try Self.methodBody(
            named: "shutdownOnce",
            in: source,
            endingAt: "nonisolated func closeOnce("
        )
        try Self.assertSyscallInsideLock(body: shutdownBody, syscall: "Darwin.shutdown(", label: "shutdownOnce")

        let closeOnceBody = try Self.methodBody(
            named: "closeOnce",
            in: source,
            endingAt: "\n/// A socketpair bridge"
        )
        try Self.assertSyscallInsideLock(body: closeOnceBody, syscall: "Darwin.shutdown(", label: "closeOnce")
        try Self.assertSyscallInsideLock(body: closeOnceBody, syscall: "Darwin.close(", label: "closeOnce")
    }

    // MARK: - Helpers

    /// Register descriptor closes that run on every path, including an abort.
    /// XCTest does not guarantee Swift `defer` runs when
    /// `continueAfterFailure = false` aborts a test, so cleanup that only
    /// closes descriptors belongs here. `fcntl(F_GETFD)` skips a number the
    /// closer already released (so a stale close cannot land on a reused
    /// descriptor).
    private func addDescriptorTeardown(_ fds: [Int32]) {
        addTeardownBlock {
            for fd in fds where fd >= 0 && Darwin.fcntl(fd, F_GETFD) != -1 {
                Darwin.close(fd)
            }
        }
    }


    /// The nearest preceding declaration-shaped `func name(` line for a call
    /// site (line index based). Only a line whose preamble before `func` is
    /// empty or modifier-shaped (identifiers, `@` attributes, whitespace) can
    /// match, so a block comment or a string containing `func ` cannot shadow
    /// the real declaration; extracting the wrong name still fails loudly
    /// against the allowlist.
    private static func enclosingFunctionName(before index: Int, in lines: [String]) -> String? {
        guard index > 0 else { return nil }
        for lineIndex in stride(from: index - 1, through: 0, by: -1) {
            let line = lines[lineIndex]
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            guard let funcRange = line.range(of: "func ") else { continue }
            let preamble = line[line.startIndex..<funcRange.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let preambleIsModifierShaped = preamble.split(separator: " ").allSatisfy { token in
                token.allSatisfy { character in
                    character.isLetter || character.isNumber || character == "_" || character == "@"
                }
            }
            guard preambleIsModifierShaped else { continue }
            let remainder = line[funcRange.upperBound...]
            guard let paren = remainder.firstIndex(of: "(") else { continue }
            let name = remainder[remainder.startIndex..<paren]
            guard !name.isEmpty else { continue }
            return String(name)
        }
        return nil
    }

    /// Slice a closer method body from its declaration to `endingAt` (or EOF).
    private static func methodBody(named name: String, in source: String, endingAt terminator: String?) throws -> Substring {
        let declaration = "nonisolated func \(name)(_ fd: Int32)"
        let start = try XCTUnwrap(source.range(of: declaration), "\(name) declaration not found")
        let tail = source[start.lowerBound...]
        guard let terminator else { return tail }
        let end = try XCTUnwrap(tail.range(of: terminator), "\(name) body end not found")
        return tail[tail.startIndex..<end.lowerBound]
    }

    /// A comment-stripped copy of `source` for the token scans: characters
    /// inside `//` line comments and nested `/* … */` block comments become
    /// spaces; newlines are preserved, so line numbers and slice anchors still
    /// resolve. String contents are copied verbatim (so a `//` inside a
    /// literal is not read as a comment); the scanner covers `"…"` (with `\`
    /// escapes) and `"""…"""`, not raw strings (``#"…"#``) or comments
    /// inside an interpolation. FORMATTING HEURISTIC class, like the other
    /// pins: a token inside a string literal can still satisfy a scan.
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

    /// The body span `{ … }` of the first brace-delimited block after `anchor`,
    /// found by a character-level depth walk from its opening brace.
    ///
    /// Same FORMATTING HEURISTIC class as the other pins: the walk does not
    /// strip string literals, so a brace inside a literal in the slice would
    /// unbalance the match (callers pass a comment-stripped slice, so a brace
    /// in a comment cannot). A mis-slice cannot pass vacuously: an absent or
    /// unbalanced block fails the `XCTUnwrap` here, and the containment
    /// asserts it feeds fail when a pinned token sits outside.
    private static func bracedBlock(
        after anchor: Range<String.Index>,
        in text: String
    ) throws -> Range<String.Index> {
        let open = try XCTUnwrap(
            text[anchor.upperBound...].firstIndex(of: "{"),
            "the pin anchor must be followed by a `{`"
        )
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
        let blockClose = try XCTUnwrap(close, "the pin anchor's braces must balance")
        return text.index(after: open)..<blockClose
    }

    /// Whether `index` falls strictly inside the `block` span (the span
    /// returned by `bracedBlock` excludes the braces themselves).
    private static func isInside(_ block: Range<String.Index>, _ index: String.Index) -> Bool {
        block.lowerBound < index && index < block.upperBound
    }

    /// Assert `syscall` occurs only inside the `state.withLock { … }` body of
    /// `body` — the lexical stand-in for the preemption window the in-lock
    /// syscalls close. The body is comment-stripped first, so a commented-out
    /// syscall cannot satisfy (or trip) the assertion.
    private static func assertSyscallInsideLock(body: Substring, syscall: String, label: String) throws {
        let text = Self.strippingComments(String(body))
        let lock = try XCTUnwrap(text.range(of: "state.withLock {"), "\(label): no state.withLock found")

        var depth = 0
        var lockClose: String.Index?
        var index = lock.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    lockClose = text.index(after: index)
                    break
                }
            }
            index = text.index(after: index)
        }
        let lockEnd = try XCTUnwrap(lockClose, "\(label): unbalanced state.withLock braces")

        var occurrences: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: syscall, range: searchStart..<text.endIndex) {
            occurrences.append(range)
            searchStart = range.upperBound
        }
        XCTAssertFalse(occurrences.isEmpty, "\(label): \(syscall) not found")
        for range in occurrences {
            XCTAssertGreaterThan(
                range.lowerBound,
                lock.lowerBound,
                "\(label): \(syscall) must run inside state.withLock"
            )
            XCTAssertLessThan(
                range.lowerBound,
                lockEnd,
                "\(label): \(syscall) appears after the lock's closing brace"
            )
        }
    }

    /// The proxy transport source (the closer's declaration + the proxy pump).
    private func proxySource() throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("VVTerm/Features/Teleport/Infrastructure/SSHProxySubsystemTransport.swift"),
            encoding: .utf8
        )
    }

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSHTLSTransportPumpFDCloserTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportPumpFDCloserTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }
}

#endif // canImport(Network)
