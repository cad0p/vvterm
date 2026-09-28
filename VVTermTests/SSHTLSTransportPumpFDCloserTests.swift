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
//  source pins at the bottom of this file keep that ordering from regressing,
//  including the connect-failure gate and the proxy twin
//  (`SSHProxySubsystemTransport.swift`), which the package does not carry.
//
//  XCTest (the host target also runs Swift Testing): this is the XCTest
//  counterpart of the package's suite, adapted to the host types. XCTest is
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

    /// A source-level tripwire: no line in `SSHTLSTransport.swift` may contain
    /// both `Darwin.close(` and `pumpFD` — every close of the pump end must
    /// route through `PumpFDCloser`. This is a FORMATTING HEURISTIC, NOT A
    /// PROOF: it is defeated by an unqualified `close(pumpFD)`, a multi-line
    /// call, or `let fd = pair.pumpFD; Darwin.close(fd)`. The behavioural test
    /// above is the real gate; this only catches the obvious reintroduction.
    func testPumpEndIsClosedOnlyThroughTheSingleOwnerGuard() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("VVTerm/Features/Teleport/Infrastructure/SSHTLSTransport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let rawPumpCloses = source
            .components(separatedBy: .newlines)
            .filter { $0.contains("Darwin.close(") && $0.contains("pumpFD") }
        XCTAssertTrue(
            rawPumpCloses.isEmpty,
            "the pump fd must only be closed by PumpFDCloser; found: \(rawPumpCloses)"
        )
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
        let pair = try SSHTLSTransport.makeSocketPair()
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
        let pair = try SSHTLSTransport.makeSocketPair()
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
        let pair = try SSHTLSTransport.makeSocketPair()
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
        let pair = try SSHTLSTransport.makeSocketPair()

        // The unrelated descriptor the freed number is reused for is a real
        // socket, so a stale wake is observable on the wire. It comes from
        // `makeSocketPair` so `SO_NOSIGPIPE` is set (the write below must not
        // raise SIGPIPE even under a mutation).
        let unrelated = try SSHTLSTransport.makeSocketPair()
        // `pair.pumpFD` is listed up front: by teardown time the closer has
        // freed it and `dup2` has reused it for `unrelated.pumpFD`, so both
        // live descriptors must be closed; a number the closer freed without
        // reuse fails the `F_GETFD` guard and is skipped.
        addDescriptorTeardown([pair.libssh2FD, unrelated.libssh2FD, unrelated.pumpFD, pair.pumpFD])

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

    /// `writeAllToPumpFD` must leave its EAGAIN retry loop when the pump task
    /// is cancelled — otherwise `runPump`'s join could never complete on a
    /// full socketpair buffer with no reader.
    func testWriteAllToPumpFDEscapesACancelledFullBuffer() async throws {
        let pair = try SSHTLSTransport.makeSocketPair()

        // Fill the buffer to EAGAIN; the peer never reads.
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

        // One more byte: the helper can never finish it while the buffer is
        // full and nothing drains it — only cancellation (or the fd closing)
        // can end the loop.
        let done = OSAllocatedUnfairLock(initialState: false)
        let writeTask = Task {
            let result = await SSHTLSTransport.writeAllToPumpFD(fd: pair.pumpFD, data: Data([0x42]))
            done.withLock { $0 = true }
            return result
        }
        writeTask.cancel()
        // Teardown on every path (including an abort): closing the peer turns
        // a still-spinning EAGAIN write into an immediate EPIPE, so a failed
        // mutation cannot leave a task spinning through the suite, and the
        // descriptors cannot leak.
        addTeardownBlock {
            Darwin.close(pair.libssh2FD)
            _ = await writeTask.value
            if Darwin.fcntl(pair.pumpFD, F_GETFD) != -1 { Darwin.close(pair.pumpFD) }
        }
        let escaped = await Self.waitFor(timeout: 5) { done.withLock { $0 } }

        XCTAssertTrue(escaped, "writeAllToPumpFD did not observe cancellation within the deadline")
    }

    /// `close()` releases the pump fd through `runPump` after the join on two
    /// paths that could otherwise strand it: a large outstanding
    /// `NWConnection` send, and the actor being released before the pump ends.
    ///
    /// Honest scope: whether the FD→NW loop is *provably* parked in `send` is
    /// not observable from here, so leg (i) is a hang regression test (it
    /// fails if the join does not complete), and leg (ii) asserts the release
    /// outcome rather than a forced interleaving.
    @MainActor
    func testCloseReleasesThePumpFdWithAParkedSendAndAfterActorRelease() async throws {
        // Leg (i): a large outstanding send, then close().
        do {
            let identity = try LoopbackTLSServerTestSupport.identity(named: "server.p12")
            let server = try LoopbackTLSServer(
                identity: identity,
                alpnProtocols: [SSHTLSTransport.alpnProtocol, "h2"]
            )
            // Teardown blocks, not `defer`: XCTest does not guarantee Swift
            // `defer` runs when a failed `XCTUnwrap` aborts the test, and a
            // throwing path here would otherwise leak the transport, the
            // libssh2 fd and the loopback server.
            addTeardownBlock { server.stop() }

            let transport = Self.makeLoopbackTransport(server: server)
            let fd = try await transport.connect()
            addTeardownBlock {
                await transport.close()
                if Darwin.fcntl(fd, F_GETFD) != -1 { Darwin.close(fd) }
            }

            // Push more than any plausible socket send buffer: the loopback
            // fixture accepts and never reads, so the pump's `connection.send`
            // stops completing and the socketpair fills behind it. A buffer
            // that stays full for a second proves the park; the target is only
            // there for the case where the pipe drains faster than the peer
            // stops reading.
            let chunk = Data(repeating: 0x5A, count: 64 * 1024)
            let target = 8 * 1024 * 1024
            var pushed = 0
            var stalledSince: Date?
            let writeDeadline = Date().addingTimeInterval(10)
            while pushed < target, Date() < writeDeadline {
                let n = chunk.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base, raw.count)
                }
                if n > 0 {
                    pushed += n
                    stalledSince = nil
                    continue
                }
                if n < 0, Darwin.errno == EAGAIN {
                    let stalled = stalledSince ?? Date()
                    stalledSince = stalled
                    if Date().timeIntervalSince(stalled) > 1 { break }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    continue
                }
                break
            }
            XCTAssertGreaterThan(
                pushed, 0,
                "the test pushed into the socketpair (the writes feed it; the buffer alone absorbs the first ~8 KiB)"
            )

            let capturedCloser = await transport.pumpFDCloserForTesting
            let closer = try XCTUnwrap(capturedCloser)
            await transport.close()
            let released = await Self.waitFor(timeout: 10) { closer.stateForTesting == .closed }
            let capturedPumpFD = await transport.pumpFdForTesting
            let pumpFD = try XCTUnwrap(capturedPumpFD)

            if released {
                // A second close() must not touch the number, even after it
                // has been reused for an unrelated file.
                XCTAssertEqual(Darwin.fcntl(pumpFD, F_GETFD), -1)
                let unrelated = Darwin.open("/dev/null", O_RDONLY)
                XCTAssertGreaterThanOrEqual(unrelated, 0)
                XCTAssertEqual(Darwin.dup2(unrelated, pumpFD), pumpFD)
                if unrelated != pumpFD { Darwin.close(unrelated) }
                await transport.close()
                XCTAssertNotEqual(
                    Darwin.fcntl(pumpFD, F_GETFD),
                    -1,
                    "a second close() touched the reused pump-fd number"
                )
                Darwin.close(pumpFD)
            } else {
                XCTFail("close() must release the pump fd with a large outstanding send (hang regression for the parked-send case)")
            }
        }

        // Leg (ii): the actor is released before the pump finishes. The
        // descriptor must still be released — the pump body owns it, not the
        // actor.
        do {
            let identity = try LoopbackTLSServerTestSupport.identity(named: "server.p12")
            let server = try LoopbackTLSServer(
                identity: identity,
                alpnProtocols: [SSHTLSTransport.alpnProtocol, "h2"]
            )
            var transport: SSHTLSTransport? = Self.makeLoopbackTransport(server: server)
            // Registered BEFORE `connect()`, which can throw: a throwing path
            // would otherwise fall back to `LoopbackTLSServer.deinit`, which
            // cancels only the listener. The fd box tolerates the
            // pre-connect case (-1): when `connect()` fails there is no
            // returned fd to close, and the transport's own catch releases
            // the pump side. When a later unwrap aborts after `connect()`,
            // dropping the transport releases the actor and stopping the
            // server cancels the connection, so the pump's detached body
            // (which holds the pair/closer strongly) still releases `pumpFD`.
            let fdBox = OSAllocatedUnfairLock(initialState: Int32(-1))
            addTeardownBlock {
                let fd = fdBox.withLock { $0 }
                if fd >= 0, Darwin.fcntl(fd, F_GETFD) != -1 { Darwin.close(fd) }
                server.stop()
            }
            let fd = try await XCTUnwrap(transport).connect()
            fdBox.withLock { $0 = fd }

            let capturedPumpFD = await transport?.pumpFdForTesting
            let pumpFD = try XCTUnwrap(capturedPumpFD)
            let capturedCloser = await transport?.pumpFDCloserForTesting
            let closer = try XCTUnwrap(capturedCloser)

            await transport?.close()
            transport = nil   // release the actor; only the pump task still runs

            let released = await Self.waitFor(timeout: 10) {
                Darwin.fcntl(pumpFD, F_GETFD) == -1
            }
            XCTAssertTrue(released, "the pump must release the fd after the actor is released")
            XCTAssertEqual(closer.stateForTesting, .closed)
        }
    }

    /// The socketpair-buffer variant of the wake test, pinning the measured
    /// `shutdown(2)` behaviour that makes the pre-join wake a **prompt** exit:
    /// with the buffer full to EAGAIN, the next write returns `EPIPE` (not
    /// `EAGAIN`) and the pump end reads EOF — while `fcntl(F_GETFD)` still
    /// succeeds. `read(pair.pumpFD)` is named deliberately: a read on
    /// `libssh2FD` would return queued bytes first.
    func testShutdownUnblocksAFullBufferWrite() throws {
        continueAfterFailure = false
        let pair = try SSHTLSTransport.makeSocketPair()
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

    /// Lexical pins for the shutdown/release split. These are **heuristics,
    /// not proofs**: they slice the source on exact declaration text, so a
    /// rename or a reshuffle fails loudly instead of silently disarming the
    /// behavioural tests above. The behavioural counterexamples they stand in
    /// for cannot be forced deterministically (a preemption window between a
    /// state check and a syscall is exactly what the in-lock design removes).
    func testPumpSourcePinsHoldAfterTheSplit() throws {
        let sourceURL = repositoryRoot()
            .appendingPathComponent("VVTerm/Features/Teleport/Infrastructure/SSHTLSTransport.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = source.components(separatedBy: .newlines)

        // (a) Every closeOnce( call site lives in an allowlisted function.
        // `close()` must never release the number itself — only wake it. The
        // closer is declared in the proxy transport file, so this file has
        // exactly the two call sites (connect-failure + runPump).
        let closeOnceLines = lines.enumerated().filter { _, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            return line.contains("closeOnce(")
        }
        XCTAssertEqual(
            closeOnceLines.count,
            2,
            "expected the two closeOnce( call sites (connect-failure and runPump-after-join); re-derive this pin"
        )
        var enclosingFunctions: [String] = []
        for (index, line) in closeOnceLines where !line.contains("func closeOnce(") {
            let enclosing = try XCTUnwrap(
                Self.enclosingFunctionName(before: index, in: lines),
                "no enclosing function for the closeOnce( call on line \(index + 1)"
            )
            enclosingFunctions.append(enclosing)
        }
        XCTAssertEqual(
            Set(enclosingFunctions),
            ["connect", "runPump"],
            "closeOnce( may only be reached from the connect-failure path and runPump-after-join"
        )

        let closeStart = try XCTUnwrap(source.range(of: "func close()"), "close() declaration not found")
        let closeTail = source[closeStart.lowerBound...]
        let closeEnd = try XCTUnwrap(
            closeTail.range(of: "\n    // MARK: - Test seams"),
            "close() slice end not found"
        )
        XCTAssertFalse(
            closeTail[closeTail.startIndex..<closeEnd.lowerBound].contains("closeOnce("),
            "close() must only wake the pump end; the release belongs to runPump after the join"
        )

        // (b) runPump's body: wake before the join, release after it, and no
        // actor capture in the detached pump-start closure.
        let runPumpStart = try XCTUnwrap(
            source.range(of: "nonisolated private static func runPump("),
            "runPump must keep the pinned static declaration"
        )
        let runPumpTail = source[runPumpStart.lowerBound...]
        let runPumpEnd = try XCTUnwrap(
            runPumpTail.range(of: "\n    nonisolated private static func pumpNWToFD("),
            "runPump body end not found"
        )
        let runPumpBody = runPumpTail[runPumpTail.startIndex..<runPumpEnd.lowerBound]
        let joinAnchor = try XCTUnwrap(
            runPumpBody.range(of: "await group.waitForAll()"),
            "runPump must join both loops before releasing the descriptor"
        )
        let beforeJoin = runPumpBody[runPumpBody.startIndex..<joinAnchor.lowerBound]
        let afterJoin = runPumpBody[joinAnchor.upperBound...]
        XCTAssertTrue(beforeJoin.contains("shutdownOnce("), "the pre-join wake must stay in runPump")
        XCTAssertFalse(beforeJoin.contains("closeOnce("), "closeOnce( must not run before the join")
        XCTAssertTrue(afterJoin.contains("closeOnce("), "runPump must release the descriptor after the join")

        let pumpStart = try XCTUnwrap(
            source.range(of: "Task.detached(priority: .userInitiated)"),
            "the pump must start in a detached task"
        )
        let pumpStartTail = source[pumpStart.lowerBound...]
        let pumpStartEnd = try XCTUnwrap(
            pumpStartTail.range(of: "// Wait for the connection to be ready"),
            "pump-start closure slice end not found"
        )
        let pumpStartClosure = pumpStartTail[pumpStartTail.startIndex..<pumpStartEnd.lowerBound]
        XCTAssertFalse(
            pumpStartClosure.contains("weak self"),
            "the pump body must not capture the actor weakly"
        )
        XCTAssertFalse(
            pumpStartClosure.contains("guard let self"),
            "the pump body must not be able to skip the release when the actor is gone"
        )

        // (c) The closer's in-lock syscalls are pinned in the proxy case
        // below (the closer is declared there, shared by both pumps).

        // (d) The connect-failure path's ordering: the release is gated on
        // this path owning the pump task, wakes before the join, and runs
        // after it — all inside the gate's braces. Deleting `await pump.value`
        // from the catch used to leave the whole suite green, so this slice is
        // the only pin for it. Same formatting-heuristic caveat as the pins
        // above, and the containment asserts share it: `bracedBlock` is a
        // character-level depth walk that does not strip string literals or
        // comments, so a brace in either inside this slice would unbalance the
        // gate span — the `XCTUnwrap` anchors keep that a loud failure rather
        // than a silent pass.
        let connectCatchStart = try XCTUnwrap(
            source.range(of: "let pump = pumpTask"),
            "the connect-failure catch must capture the pump task first"
        )
        let connectCatchTail = source[connectCatchStart.lowerBound...]
        let connectCatchEnd = try XCTUnwrap(
            connectCatchTail.range(of: "throw TeleportPackageError.connectionFailed"),
            "the connect-failure catch slice end not found"
        )
        let connectCatch = connectCatchTail[connectCatchTail.startIndex..<connectCatchEnd.lowerBound]
        let gateAnchor = try XCTUnwrap(
            connectCatch.range(of: "if let pump"),
            "the connect-failure release must be gated on owning the pump task"
        )
        let gateBody = try Self.bracedBlock(after: gateAnchor, in: connectCatch)
        let connectJoin = try XCTUnwrap(
            connectCatch.range(of: "await pump"),
            "the connect-failure path must join the pump before releasing"
        )
        XCTAssertTrue(
            connectCatch[connectCatch.startIndex..<connectJoin.lowerBound].contains("shutdownOnce("),
            "the connect-failure path must wake the pump before the join"
        )
        let connectWake = try XCTUnwrap(
            connectCatch.range(of: "shutdownOnce("),
            "the connect-failure path must wake the pump before the join"
        )
        XCTAssertTrue(
            Self.isInside(gateBody, connectWake.lowerBound),
            "the connect-failure wake must sit inside the `if let pump` gate"
        )
        XCTAssertTrue(
            Self.isInside(gateBody, connectJoin.lowerBound),
            "the connect-failure join must sit inside the `if let pump` gate"
        )
        var connectCloseOnceRanges: [Range<String.Index>] = []
        var connectSearchStart = connectCatch.startIndex
        while let range = connectCatch.range(of: "closeOnce(", range: connectSearchStart..<connectCatch.endIndex) {
            connectCloseOnceRanges.append(range)
            connectSearchStart = range.upperBound
        }
        XCTAssertEqual(
            connectCloseOnceRanges.count,
            1,
            "the connect-failure path must release exactly once"
        )
        let connectRelease = try XCTUnwrap(
            connectCloseOnceRanges.first,
            "the connect-failure path must release the pump fd"
        )
        XCTAssertGreaterThan(
            connectRelease.lowerBound,
            connectJoin.upperBound,
            "the connect-failure release must run after the join"
        )
        XCTAssertTrue(
            Self.isInside(gateBody, connectRelease.lowerBound),
            "the connect-failure release must sit inside the `if let pump` gate"
        )
    }

    /// Host-only pins for the proxy twin (`SSHProxySubsystemTransport.swift`):
    /// the package has no equivalent file, and its pump wakes differently —
    /// no `NWConnection`, so `runPump` flips the channel `PumpCancelToken`
    /// before the join. Lexical heuristics, same caveats as the TLS pins above.
    func testProxyPumpSourcePinsHoldAfterTheSplit() throws {
        let source = try proxySource()
        let lines = source.components(separatedBy: .newlines)

        // The closer stays declared exactly once, in this file, shared by both
        // pumps; the TLS transport must not grow a second declaration.
        XCTAssertEqual(
            lines.filter { $0.contains("class PumpFDCloser") }.count,
            1,
            "PumpFDCloser must be declared exactly once, in the proxy transport file"
        )
        let tlsSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("VVTerm/Features/Teleport/Infrastructure/SSHTLSTransport.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            tlsSource.contains("class PumpFDCloser"),
            "PumpFDCloser must not be declared a second time in SSHTLSTransport.swift"
        )

        // (a) Every closeOnce( call site lives in runPump — the proxy has no
        // handshake-failure path. `cancelPumpSync()` must only wake.
        let closeOnceLines = lines.enumerated().filter { _, line in
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
                Self.enclosingFunctionName(before: index, in: lines),
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
        let cancelBody = cancelTail[cancelTail.startIndex..<cancelEnd.lowerBound]
        XCTAssertFalse(
            cancelBody.contains("closeOnce("),
            "cancelPumpSync() must only wake the pump end; the release belongs to runPump after the join"
        )
        XCTAssertTrue(
            cancelBody.contains("shutdownOnce("),
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
        let runPumpBody = runPumpTail[runPumpTail.startIndex..<runPumpEnd.lowerBound]
        let joinAnchor = try XCTUnwrap(
            runPumpBody.range(of: "await group.waitForAll()"),
            "runPump must join both loops before releasing the descriptor"
        )
        let beforeJoin = runPumpBody[runPumpBody.startIndex..<joinAnchor.lowerBound]
        let afterJoin = runPumpBody[joinAnchor.upperBound...]
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
        let pumpStartClosure = pumpStartTail[pumpStartTail.startIndex..<pumpStartEnd.lowerBound]
        XCTAssertFalse(
            pumpStartClosure.contains("weak self"),
            "the pump body must not capture the actor weakly"
        )
        XCTAssertFalse(
            pumpStartClosure.contains("guard let self"),
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

    /// Poll `condition` until it is true or the timeout elapses. The bounded
    /// deadline is the assertion: a hung join must fail this test rather than
    /// hang the suite.
    private static func waitFor(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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

    /// The body span `{ … }` of the first brace-delimited block after `anchor`,
    /// found by a character-level depth walk from its opening brace.
    ///
    /// Same FORMATTING HEURISTIC class as the other pins: the walk does not
    /// strip string literals or comments, so a brace inside either inside the
    /// slice would unbalance the match. A mis-slice cannot pass vacuously: an
    /// absent or unbalanced block fails the `XCTUnwrap` here, and the
    /// containment asserts it feeds fail when a pinned token sits outside.
    private static func bracedBlock(
        after anchor: Range<String.Index>,
        in text: Substring
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
    /// syscalls close.
    private static func assertSyscallInsideLock(body: Substring, syscall: String, label: String) throws {
        let text = String(body)
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

    /// A loopback transport for the fixture server (the helper the transport
    /// suite uses, kept local so this file owns no shared fixture state).
    @MainActor
    private static func makeLoopbackTransport(server: LoopbackTLSServer) -> SSHTLSTransport {
        SSHTLSTransport(
            host: "127.0.0.1",
            port: Int(server.port),
            clusterName: "ci-cluster",
            clusterCAPEMs: [loopbackCAPEM],
            logging: DefaultTeleportLogging()
        )
    }

    @MainActor
    private static let loopbackCAPEM: String = {
        (try? LoopbackTLSServerTestSupport.pemString("loopback-tls/loopback-ca.pem")) ?? ""
    }()

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSHTLSTransportPumpFDCloserTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportPumpFDCloserTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }
}

#endif // canImport(Network)
