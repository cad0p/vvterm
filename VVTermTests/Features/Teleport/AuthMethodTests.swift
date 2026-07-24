// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  AuthMethodTests.swift
//  VVTermTests
//
//  Layer 1 unit tests for `AuthMethod.faceIDTeleport`:
//    - Codable round-trip (encode → decode preserves the case)
//    - Back-compat: decoding an old `Server` JSON (persisted before
//      `.faceIDTeleport` existed) doesn't break — `decodeIfPresent ?? .password`
//      means a missing `authMethod` field decodes to `.password`.
//    - Raw value stability: the raw value `"faceIDTeleport"` is the on-disk
//      identifier (CloudKit-synced, UserDefaults-persisted) and must not change.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (CI strategy
//      Layer 1 — "back-compat: decoding an old Server with no .faceIDTeleport
//      doesn't break")
//    - VVTerm/Features/Servers/Domain/Server.swift (AuthMethod + Server.init(from:))
//    - VVTerm commit 9b9dd13 (added .faceIDTeleport + decodeIfPresent fallback)
//

import XCTest
@testable import VVTerm

final class AuthMethodTests: XCTestCase {

    // MARK: - .faceIDTeleport raw value stability

    func testFaceIDTeleportRawValueIsStable() {
        // The raw value is the on-disk identifier (CloudKit + UserDefaults).
        // Changing it would break every persisted Server using this method.
        XCTAssertEqual(AuthMethod.faceIDTeleport.rawValue, "faceIDTeleport")
    }

    func testFaceIDTeleportInitFromRawValue() {
        XCTAssertEqual(AuthMethod(rawValue: "faceIDTeleport"), .faceIDTeleport)
    }

    // MARK: - Codable round-trip

    func testFaceIDTeleportCodableRoundTrip() {
        // A standalone AuthMethod.faceIDTeleport round-trips through Codable.
        let original = AuthMethod.faceIDTeleport
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(AuthMethod.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAllAuthMethodsCodableRoundTrip() {
        // Every case round-trips (catches raw-value typos on new cases).
        for method in AuthMethod.allCases {
            let data = try! JSONEncoder().encode(method)
            let decoded = try! JSONDecoder().decode(AuthMethod.self, from: data)
            XCTAssertEqual(decoded, method, "round-trip failed for \(method)")
        }
    }

    func testAuthMethodEncodesAsRawValueString() {
        // AuthMethod is a String-backed enum → encodes as the raw value,
        // not as a JSON object. This is what the on-disk format expects.
        let data = try! JSONEncoder().encode(AuthMethod.faceIDTeleport)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(json, #""faceIDTeleport""#)
    }

    // MARK: - Back-compat: decoding an old Server

    func testDecodingOldServerWithoutAuthMethodFieldFallsBackToPassword() {
        // An old `Server` JSON (persisted before .faceIDTeleport existed)
        // may not have an `authMethod` field at all. The custom decoder uses
        // `decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password`,
        // so a missing field decodes to `.password` (the default) rather than
        // throwing.
        //
        // This is the critical back-compat guarantee: existing users' saved
        // servers don't break when they upgrade to a build that added
        // .faceIDTeleport.
        let serverJSON = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "workspaceId": "00000000-0000-0000-0000-000000000002",
            "name": "Old Server",
            "host": "example.com",
            "username": "user",
            "port": 22
        }
        """#.data(using: .utf8)!

        let server = try! JSONDecoder().decode(Server.self, from: serverJSON)
        XCTAssertEqual(server.authMethod, .password)
    }

    func testDecodingOldServerWithExplicitPasswordAuthMethodDecodesToPassword() {
        // A server JSON with an explicit "authMethod": "password" decodes to
        // .password (no regression on the existing case).
        let serverJSON = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "workspaceId": "00000000-0000-0000-0000-000000000002",
            "name": "Old Server",
            "host": "example.com",
            "username": "user",
            "port": 22,
            "authMethod": "password"
        }
        """#.data(using: .utf8)!

        let server = try! JSONDecoder().decode(Server.self, from: serverJSON)
        XCTAssertEqual(server.authMethod, .password)
    }

    func testDecodingServerWithFaceIDTeleportAuthMethodDecodesCorrectly() {
        // A new server JSON with "authMethod": "faceIDTeleport" decodes to
        // .faceIDTeleport (the forward path).
        let serverJSON = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "workspaceId": "00000000-0000-0000-0000-000000000002",
            "name": "Teleport Server",
            "host": "teleport.pcad.it",
            "username": "pier",
            "port": 443,
            "authMethod": "faceIDTeleport"
        }
        """#.data(using: .utf8)!

        let server = try! JSONDecoder().decode(Server.self, from: serverJSON)
        XCTAssertEqual(server.authMethod, .faceIDTeleport)
    }

    func testDecodingOldServerWithUnknownAuthMethodFallsBackToPassword() {
        // A server JSON with an unknown authMethod raw value (e.g. from a
        // future build that added a case this build doesn't know about) —
        // AuthMethod(rawValue:) returns nil, and decodeIfPresent returns nil,
        // so the fallback kicks in: .password. This prevents a crash on
        // upgrade from a newer to an older build.
        //
        // NOTE: This is the behavior of `decodeIfPresent` + the nil-coalescing
        // fallback. The unknown raw value decodes to nil (not an error),
        // and `?? .password` provides the default.
        let serverJSON = #"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "workspaceId": "00000000-0000-0000-0000-000000000002",
            "name": "Future Server",
            "host": "example.com",
            "username": "user",
            "port": 22,
            "authMethod": "someFutureMethod"
        }
        """#.data(using: .utf8)!

        let server = try! JSONDecoder().decode(Server.self, from: serverJSON)
        XCTAssertEqual(server.authMethod, .password)
    }

    // MARK: - Round-trip through Server

    func testServerWithFaceIDTeleportRoundTripsThroughCodable() {
        // A Server with .faceIDTeleport survives a full encode → decode cycle.
        let original = Server(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            environment: .production,
            name: "Teleport Cluster",
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            authMethod: .faceIDTeleport
        )

        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(Server.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.port, 443)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.authMethod, .faceIDTeleport)
    }

    // MARK: - CaseIterable / Identifiable

    func testFaceIDTeleportIsInAllCases() {
        // .faceIDTeleport is part of the CaseIterable set (used by the method
        // picker in ServerFormSheet).
        XCTAssertTrue(AuthMethod.allCases.contains(.faceIDTeleport))
    }

    func testFaceIDTeleportIDMatchesRawValue() {
        // Identifiable.id is the rawValue — used by SwiftUI pickers (ForEach
        // over AuthMethod.allCases).
        XCTAssertEqual(AuthMethod.faceIDTeleport.id, "faceIDTeleport")
    }

    // MARK: - displayName (smoke test — not strictly part of the contract)

    func testFaceIDTeleportDisplayNameIsLocalized() {
        // The display name is "Face ID (Teleport)" (the localized string).
        // We don't assert the exact localized value here (it depends on the
        // bundle's Localizable.strings), but we assert it's non-empty and
        // distinct from the other methods.
        let name = AuthMethod.faceIDTeleport.displayName
        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, AuthMethod.password.displayName)
    }

    func testFaceIDTeleportIconIsFaceID() {
        // The SF Symbol for the method picker (faceid on iOS).
        // On macOS this maps to touchid via adaptive logic in the UI layer.
        XCTAssertEqual(AuthMethod.faceIDTeleport.icon, "faceid")
    }
}
