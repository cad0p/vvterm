// SPDX-License-Identifier: MIT
//
//  HeadlessIDTests.swift
//  VVTermTests
//
//  Golden-vector coverage for `HeadlessID.compute` — the UUIDv5-style id that
//  identifies a headless authentication request on both the blocking POST
//  (/webapi/headless/login) and the web approval page (/web/headless/<id>).
//
//  The golden literals were produced by the real library Teleport uses:
//  `uuid.NewHash(sha256.New(), uuid.Nil, data, 5).String()` (google/uuid
//  v1.6.0, hash.go). That is an independent oracle (different language +
//  library). The allowlisted `scripts/ci/teleport-webauthn.py` helper is a
//  port of the same Go function, so it is a cross-language check only — not
//  the source of truth.
//
//  Facts pinned at once: SHA-256 (not RFC 9562's SHA-1 default), the
//  16-zero-byte namespace, the appended "\n", and the version/variant bits.

import XCTest
@testable import VVTerm

final class HeadlessIDTests: XCTestCase {

    /// A newline-free authorized_keys line — the shape the sole caller
    /// (`TeleportBootstrapCoordinator.begin`) passes in.
    private static let authorizedKeyLine =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey vvterm-headless-id-vector"

    // Golden UUIDs from google/uuid v1.6.0
    // `uuid.NewHash(sha256.New(), uuid.Nil, data, 5)`:
    //   data = line          -> 2397e102-de23-5398-bc9b-8a49412156a7
    //   data = line + "\n"   -> 1868c232-9b78-5b00-b118-fc86ac54cf8c
    //   data = line + "\n\n" -> 8e81b3df-6b6c-599f-a803-ec25bd63f607
    private static let goLineID = "2397e102-de23-5398-bc9b-8a49412156a7"
    private static let goLineNewlineID = "1868c232-9b78-5b00-b118-fc86ac54cf8c"
    private static let goLineTwoNewlinesID = "8e81b3df-6b6c-599f-a803-ec25bd63f607"

    func testCompute_matchesTheGoUUIDv5OracleForTheAuthorizedKeysLine() {
        // The caller passes a newline-free line; compute() appends exactly one
        // "\n", matching ssh.MarshalAuthorizedKey output. So the expected id
        // is the Go oracle over line + "\n".
        XCTAssertEqual(
            HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine),
            Self.goLineNewlineID
        )
    }

    func testCompute_appendsExactlyOneNewline() {
        // Without the appended "\n" the id would be the Go oracle over the
        // bare line — a different value.
        XCTAssertNotEqual(
            HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine),
            Self.goLineID,
            "the appended \\n is load-bearing"
        )
        // A caller that already passes a newline-terminated line gets a SECOND
        // newline hashed (no normalization) — pinned against the Go oracle.
        XCTAssertEqual(
            HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine + "\n"),
            Self.goLineTwoNewlinesID
        )
    }

    func testCompute_pinsVersionAndVariantBits() {
        let uuid = HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine)
        // 8-4-4-4-12 layout: string[14] is the version nibble, string[19] is
        // the first nibble of the variant byte.
        XCTAssertEqual(uuid.count, 36)
        XCTAssertEqual(uuid[uuid.index(uuid.startIndex, offsetBy: 14)], "5", "version must be 5")
        let variant = uuid[uuid.index(uuid.startIndex, offsetBy: 19)]
        XCTAssertTrue(
            ["8", "9", "a", "b"].contains(variant),
            "variant must be RFC 9562 (10xx), got \(variant)"
        )
        XCTAssertEqual(uuid, uuid.lowercased(), "id must be lowercase")
    }

    func testCompute_isDeterministic() {
        XCTAssertEqual(
            HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine),
            HeadlessID.compute(sshAuthorizedKey: Self.authorizedKeyLine)
        )
    }
}
