// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportCredentialTests.swift
//  VVTermTests
//
//  Layer 1 unit tests for `TeleportCredential.isCertValid` + Codable round-trip.
//
//  `isCertValid` drives the `ready` ↔ `needsLogin` readiness flip (via the
//  resolver's `certExpiry` probe) and the "Certificate valid for …" copy in
//  the login sheet. This file asserts it's `true` only when a cert is both
//  present and not expired.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (CI strategy
//      Layer 1 — "cert expiry parsing"; mockup E — dynamic TTL copy)
//    - VVTerm/Features/Teleport/Domain/TeleportCredential.swift
//

import XCTest
@testable import VVTerm

final class TeleportCredentialTests: XCTestCase {

    // MARK: - isCertValid

    func testIsCertValid_falseWhenNoCertPresent() {
        // hasLiveCert=false → not valid (no cert to present to SSHClient).
        let cred = makeCredential(hasLiveCert: false, sshCertPEM: nil, validBefore: .distantFuture)
        XCTAssertFalse(cred.isCertValid)
    }

    func testIsCertValid_falseWhenCertPresentButHasLiveCertFalse() {
        // Defensive: even if sshCertPEM is set, hasLiveCert=false means not
        // valid (the flag is the source of truth — the PEM alone isn't).
        let cred = makeCredential(
            hasLiveCert: false,
            sshCertPEM: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
            validBefore: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(cred.isCertValid)
    }

    func testIsCertValid_falseWhenHasLiveCertButNoPEM() {
        // Defensive: hasLiveCert=true but sshCertPEM is nil → not valid
        // (the PEM is what gets handed to libssh2; without it the flag is
        // meaningless). This shouldn't happen in practice (the key ring
        // sets both together) but the guard prevents a crash.
        let cred = makeCredential(hasLiveCert: true, sshCertPEM: nil, validBefore: .distantFuture)
        XCTAssertFalse(cred.isCertValid)
    }

    func testIsCertValid_falseWhenCertExpired() {
        // hasLiveCert=true + PEM present, but now >= validBefore → expired.
        let cred = makeCredential(
            hasLiveCert: true,
            sshCertPEM: "fake-cert-pem",
            validBefore: Date().addingTimeInterval(-3600)  // expired 1h ago
        )
        XCTAssertFalse(cred.isCertValid)
    }

    func testIsCertValid_falseWhenValidBeforeIsDistantPast() {
        // The "no cert" sentinel (.distantPast) → not valid.
        let cred = makeCredential(
            hasLiveCert: true,
            sshCertPEM: "fake-cert-pem",
            validBefore: .distantPast
        )
        XCTAssertFalse(cred.isCertValid)
    }

    func testIsCertValid_trueWhenCertPresentAndNotExpired() {
        // The happy path: hasLiveCert + PEM + future expiry → valid.
        let cred = makeCredential(
            hasLiveCert: true,
            sshCertPEM: "fake-cert-pem",
            validBefore: Date().addingTimeInterval(3600)  // 1h in future
        )
        XCTAssertTrue(cred.isCertValid)
    }

    func testIsCertValid_trueWhenExpiryExactlyOneSecondInFuture() {
        // Boundary: 1s in the future is still valid (Date() < validBefore).
        let cred = makeCredential(
            hasLiveCert: true,
            sshCertPEM: "fake-cert-pem",
            validBefore: Date().addingTimeInterval(1)
        )
        XCTAssertTrue(cred.isCertValid)
    }

    // MARK: - Defaults

    func testDefaults_hasLiveCertFalseAndDistantPastExpiry() {
        // A freshly-constructed credential (before any cert is stored) has
        // hasLiveCert=false + certValidBefore=.distantPast. isCertValid is
        // therefore false — the "no cert yet" state.
        let cred = TeleportCredential(
            clusterId: UUID(),
            credentialID: "",
            userHandle: "",
            publicKeyRaw: "",
            deviceName: ""
        )
        XCTAssertFalse(cred.hasLiveCert)
        XCTAssertEqual(cred.certValidBefore, .distantPast)
        XCTAssertNil(cred.sshCertPEM)
        XCTAssertFalse(cred.isCertValid)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip_preservesAllFields() {
        let original = TeleportCredential(
            clusterId: UUID(),
            credentialID: "base64url-credential-id",
            userHandle: "base64url-user-handle",
            publicKeyRaw: "base64url-pubkey-raw",
            deviceName: "vvterm-pier-iphone",
            sshCertPEM: "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
            hasLiveCert: true,
            certValidBefore: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(TeleportCredential.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.clusterId, original.clusterId)
        XCTAssertEqual(decoded.credentialID, original.credentialID)
        XCTAssertEqual(decoded.userHandle, original.userHandle)
        XCTAssertEqual(decoded.publicKeyRaw, original.publicKeyRaw)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.sshCertPEM, original.sshCertPEM)
        XCTAssertEqual(decoded.hasLiveCert, original.hasLiveCert)
        XCTAssertEqual(decoded.certValidBefore.timeIntervalSince1970, original.certValidBefore.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.isCertValid, original.isCertValid)
    }

    func testCodableRoundTrip_preservesNilPEM() {
        // A credential with no cert (sshCertPEM == nil) round-trips with
        // the nil preserved.
        let original = TeleportCredential(
            clusterId: UUID(),
            credentialID: "id",
            userHandle: "uh",
            publicKeyRaw: "pk",
            deviceName: "device"
            // sshCertPEM defaults to nil, hasLiveCert to false, certValidBefore to .distantPast
        )

        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(TeleportCredential.self, from: data)

        XCTAssertNil(decoded.sshCertPEM)
        XCTAssertFalse(decoded.hasLiveCert)
        XCTAssertEqual(decoded.certValidBefore, .distantPast)
    }

    func testCodableRoundTrip_stableAcrossMultipleEncodes() {
        // Encoding twice produces identical bytes (deterministic encoding).
        let cred = TeleportCredential(
            clusterId: UUID(),
            credentialID: "id",
            userHandle: "uh",
            publicKeyRaw: "pk",
            deviceName: "device",
            sshCertPEM: "pem",
            hasLiveCert: true,
            certValidBefore: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data1 = try! JSONEncoder().encode(cred)
        let data2 = try! JSONEncoder().encode(cred)
        XCTAssertEqual(data1, data2)
    }

    // MARK: - Hashable / Identifiable

    func testCredentialIdentifiableByID() {
        let a = TeleportCredential(clusterId: UUID(), credentialID: "x", userHandle: "y", publicKeyRaw: "z", deviceName: "d")
        let b = TeleportCredential(clusterId: UUID(), credentialID: "x", userHandle: "y", publicKeyRaw: "z", deviceName: "d")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Helpers

    private func makeCredential(
        hasLiveCert: Bool,
        sshCertPEM: String?,
        validBefore: Date
    ) -> TeleportCredential {
        TeleportCredential(
            clusterId: UUID(),
            credentialID: "test-cred-id",
            userHandle: "test-user-handle",
            publicKeyRaw: "test-pubkey-raw",
            deviceName: "vvterm-test-device",
            sshCertPEM: sshCertPEM,
            hasLiveCert: hasLiveCert,
            certValidBefore: validBefore
        )
    }
}
