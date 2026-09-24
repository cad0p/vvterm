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
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
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

    /// The repository root, derived from this file's location
    /// (`VVTermTests/SSHTLSTransportPumpFDCloserTests.swift`).
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SSHTLSTransportPumpFDCloserTests.swift
            .deletingLastPathComponent()  // VVTermTests/
    }
}

#endif // canImport(Network)
