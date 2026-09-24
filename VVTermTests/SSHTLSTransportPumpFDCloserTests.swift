// SPDX-License-Identifier: MIT
//
//  SSHTLSTransportPumpFDCloserTests.swift
//  VVTermTests
//
//  Regression coverage for the single-owner close of the `SSHTLSTransport`
//  pump end (issue #234).
//
//  The pump end of the socketpair was closed from six racing paths: the three
//  `pumpNWToFD` exits (receive error, EOF, write failure), `runPump`'s
//  task-group cleanup, `close()`, and the TLS-handshake-failure path. A
//  repeated `close(2)` is not harmless — if the process has reused that
//  descriptor number for an unrelated file, the close lands on the wrong file
//  and its next read fails with `EBADF` (observed in the extracted package's
//  parallel CI). All six paths now route through the shared `PumpFDCloser`.
//
//  XCTest (the host target also runs Swift Testing): this is the XCTest
//  counterpart of the package's Swift Testing case, adapted to the host
//  type's `closeOnce(_:)` API.
//

#if canImport(Network)
import Darwin
import XCTest
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
        defer { Darwin.close(libssh2FD) }

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
        defer { Darwin.close(pumpFD) }

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
        defer {
            Darwin.close(pair.libssh2FD)
            Darwin.close(pair.pumpFD)
        }

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

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSHTLSTransportPumpFDCloserTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportPumpFDCloserTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }
}

#endif // canImport(Network)
