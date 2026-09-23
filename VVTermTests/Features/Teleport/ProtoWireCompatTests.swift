// SPDX-License-Identifier: MIT
//
//  ProtoWireCompatTests.swift
//  VVTermTests
//
//  Golden wire bytes for the gRPC `Proto_*` messages the Teleport client
//  actually sends, plus fixed-vector decode coverage for the server
//  responses it consumes.
//
//  The goldens were captured from the PRE-REWRITE IDL (iotest_mfa.proto /
//  iotest_mfa.pb.swift as of c1a2a757, the commit this branch is based on).
//  A golden emitted after the clean-room rewrite would be self-consistent and
//  tautological: do NOT regenerate these from a rewritten IDL. A wire change
//  is a protocol break and must be a deliberate, reviewed decision.
//
//  Cross-checked independently with a hand-rolled protobuf encoder built from
//  the IDL's field numbers/types before being pinned here.

import XCTest
import SwiftProtobuf
@testable import VVTerm

final class ProtoWireCompatTests: XCTestCase {

    // MARK: - helpers

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func data(hex string: String) -> Data {
        var bytes = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    /// Asserts the message encodes to the golden bytes, the golden bytes
    /// decode, and the decoded message re-encodes byte-identically.
    private func assertWireRoundTrip<M: SwiftProtobuf.Message>(
        _ message: M,
        golden: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try message.serializedData()
        XCTAssertEqual(hex(encoded), golden, "wire bytes drifted", file: file, line: line)
        let decoded = try M(serializedBytes: data(hex: golden))
        XCTAssertEqual(
            hex(try decoded.serializedData()),
            golden,
            "golden did not re-encode byte-identically",
            file: file,
            line: line
        )
    }

    // MARK: - Requests the client sends

    func testCreateAuthenticateChallengeRequest_wireBytes() throws {
        // The Phase-2 gRPC call that starts the existing-device Browser MFA
        // flow: ContextUser (oneof 3) + ChallengeScope.MANAGE_DEVICES (nested
        // field 6) + the real loopback callback URL (field 9).
        var req = Proto_CreateAuthenticateChallengeRequest()
        req.contextUser = Proto_ContextUser()
        req.challengeExtensions = Proto_ChallengeExtensions()
        req.challengeExtensions.scope = .manageDevices
        req.browserMfaTshRedirectURL = "http://localhost:5555/callback?secret_key=deadbeef"

        try assertWireRoundTrip(
            req,
            golden: "1a00320208044a32687474703a2f2f6c6f63616c686f73743a353535352f63616c6c6261636b3f7365637265745f6b65793d6465616462656566"
        )

        let decoded = try Proto_CreateAuthenticateChallengeRequest(
            serializedBytes: data(
                hex: "1a00320208044a32687474703a2f2f6c6f63616c686f73743a353535352f63616c6c6261636b3f7365637265745f6b65793d6465616462656566"
            )
        )
        XCTAssertNotNil(decoded.request)
        if case .contextUser = decoded.request! {
            // expected
        } else {
            XCTFail("context_user oneof must survive the round-trip")
        }
        XCTAssertEqual(decoded.challengeExtensions.scope, .manageDevices)
        XCTAssertEqual(
            decoded.browserMfaTshRedirectURL,
            "http://localhost:5555/callback?secret_key=deadbeef"
        )
    }

    func testCreateRegisterChallengeRequest_withoutExistingMFA_wireBytes() throws {
        // The first-time registration call: WEBAUTHN + PASSWORDLESS, no
        // existing MFA response (field 4 absent).
        var req = Proto_CreateRegisterChallengeRequest()
        req.deviceType = .webauthn
        req.deviceUsage = .passwordless

        try assertWireRoundTrip(req, golden: "10031802")

        let decoded = try Proto_CreateRegisterChallengeRequest(
            serializedBytes: data(hex: "10031802")
        )
        XCTAssertEqual(decoded.deviceType, .webauthn)
        XCTAssertEqual(decoded.deviceUsage, .passwordless)
        XCTAssertFalse(decoded.hasExistingMfaResponse)
    }

    func testCreateRegisterChallengeRequest_withExistingBrowserMFA_wireBytes() throws {
        // The repeat-registration call after the Browser MFA ceremony: the
        // decrypted assertion rides in existing_mfa_response.browser.
        var assertion = Proto_CredentialAssertionResponse()
        assertion.type = "public-key"
        assertion.rawID = Data([1, 2, 3])
        var assertionResponse = Proto_AuthenticatorAssertionResponse()
        assertionResponse.clientDataJson = Data("cdj".utf8)
        assertionResponse.authenticatorData = Data("ad".utf8)
        assertionResponse.signature = Data([0xaa, 0xbb])
        assertionResponse.userHandle = Data([0xcc])
        assertion.response = assertionResponse
        assertion.id = "cred-1"

        var browser = Proto_BrowserMFAResponse()
        browser.requestID = "req-1"
        browser.webauthnResponse = assertion

        var existing = Proto_MFAAuthenticateResponse()
        existing.browser = browser

        var req = Proto_CreateRegisterChallengeRequest()
        req.deviceType = .webauthn
        req.deviceUsage = .passwordless
        req.existingMfaResponse = existing

        try assertWireRoundTrip(
            req,
            golden: "1003180222362a340a057265712d31122b0a0a7075626c69632d6b657912030102031a100a0363646a120261641a02aabb2201cc2a06637265642d31"
        )

        let decoded = try Proto_CreateRegisterChallengeRequest(
            serializedBytes: data(
                hex: "1003180222362a340a057265712d31122b0a0a7075626c69632d6b657912030102031a100a0363646a120261641a02aabb2201cc2a06637265642d31"
            )
        )
        XCTAssertEqual(decoded.existingMfaResponse.browser.requestID, "req-1")
        XCTAssertEqual(
            decoded.existingMfaResponse.browser.webauthnResponse.response.signature,
            Data([0xaa, 0xbb])
        )
    }

    func testAddMFADeviceSyncRequest_wireBytes() throws {
        // The final Phase-2 call: ContextUser + device name + the new
        // registration response (field 3) + PASSWORDLESS usage.
        var creation = Proto_CredentialCreationResponse()
        creation.type = "public-key"
        creation.rawID = Data([1, 2, 3])
        var attestationResponse = Proto_AuthenticatorAttestationResponse()
        attestationResponse.clientDataJson = Data("cdj".utf8)
        attestationResponse.attestationObject = Data([0xde, 0xad])
        creation.response = attestationResponse
        creation.id = "cred-1"

        var register = Proto_MFARegisterResponse()
        register.webauthn = creation

        var req = Proto_AddMFADeviceSyncRequest()
        req.newDeviceName = "iPhone"
        req.newMfaResponse = register
        req.deviceUsage = .passwordless
        req.contextUser = Proto_ContextUser()

        try assertWireRoundTrip(
            req,
            golden: "12066950686f6e651a261a240a0a7075626c69632d6b657912030102031a090a0363646a1202dead2a06637265642d3120022a00"
        )

        let decoded = try Proto_AddMFADeviceSyncRequest(
            serializedBytes: data(
                hex: "12066950686f6e651a261a240a0a7075626c69632d6b657912030102031a090a0363646a1202dead2a06637265642d3120022a00"
            )
        )
        XCTAssertEqual(decoded.newDeviceName, "iPhone")
        XCTAssertEqual(decoded.newMfaResponse.webauthn.id, "cred-1")
        XCTAssertEqual(
            decoded.newMfaResponse.webauthn.response.attestationObject,
            Data([0xde, 0xad])
        )
        XCTAssertEqual(decoded.deviceUsage, .passwordless)
    }

    // MARK: - Responses the client decodes (fixed vectors)

    func testMFAAuthenticateChallenge_browserChallengeDecode() throws {
        // Server -> client: browser_mfa_challenge (field 6) carries the
        // request id the ceremony turns into /web/mfa/browser/<id>.
        let golden = "32080a067265712d3432"
        let decoded = try Proto_MFAAuthenticateChallenge(serializedBytes: data(hex: golden))
        XCTAssertTrue(decoded.hasBrowserMfaChallenge)
        XCTAssertEqual(decoded.browserMfaChallenge.requestID, "req-42")
        XCTAssertFalse(decoded.hasWebauthnChallenge)
        XCTAssertFalse(decoded.hasTotp)
        XCTAssertEqual(hex(try decoded.serializedData()), golden)
    }

    func testMFARegisterChallenge_webauthnCreationOptionsDecode() throws {
        // Server -> client: the WebAuthn creation options for the new
        // credential (challenge, rp, user, timeout, attestation).
        let golden = "1a430a410a0401020304121c0a1074656c65706f72742e706361642e6974120854656c65706f72741a110a037569641204706965721a045069657228e0d4033a046e6f6e65"
        let decoded = try Proto_MFARegisterChallenge(serializedBytes: data(hex: golden))
        XCTAssertNotNil(decoded.request, "webauthn oneof must survive the round-trip")
        if case .webauthn = decoded.request! {
            // expected
        } else {
            XCTFail("expected the webauthn oneof case")
        }
        let options = decoded.webauthn.publicKey
        XCTAssertEqual(options.challenge, Data([1, 2, 3, 4]))
        XCTAssertEqual(options.rp.id, "teleport.pcad.it")
        XCTAssertEqual(options.rp.name, "Teleport")
        XCTAssertEqual(options.user.id, "uid")
        XCTAssertEqual(options.user.name, "pier")
        XCTAssertEqual(options.user.displayName, "Pier")
        XCTAssertEqual(options.timeoutMs, 60_000)
        XCTAssertEqual(options.attestation, "none")
        XCTAssertEqual(hex(try decoded.serializedData()), golden)
    }

    func testCredentialAssertionResponse_wireBytesRoundTrip() throws {
        // The loopback listener's decrypted payload shape: CredentialAssertionResponse
        // with the Go field numbers (type=1, raw_id=2, response=3, id=5).
        let golden = "0a0a7075626c69632d6b657912030102031a100a0363646a120261641a02aabb2201cc2a06637265642d31"
        let decoded = try Proto_CredentialAssertionResponse(serializedBytes: data(hex: golden))
        XCTAssertEqual(decoded.type, "public-key")
        XCTAssertEqual(decoded.rawID, Data([1, 2, 3]))
        XCTAssertEqual(decoded.response.clientDataJson, Data("cdj".utf8))
        XCTAssertEqual(decoded.response.authenticatorData, Data("ad".utf8))
        XCTAssertEqual(decoded.response.signature, Data([0xaa, 0xbb]))
        XCTAssertEqual(decoded.response.userHandle, Data([0xcc]))
        XCTAssertEqual(decoded.id, "cred-1")
        XCTAssertEqual(hex(try decoded.serializedData()), golden)
    }

    // MARK: - Enum contract

    func testDeviceType_reservedValueStaysReserved() {
        // `reserved 2` (DEVICE_TYPE_U2F) must not gain a named case; it
        // decodes as UNRECOGNIZED so the wire contract is visible.
        XCTAssertEqual(Proto_DeviceType.webauthn.rawValue, 3)
        XCTAssertEqual(Proto_DeviceType.totp.rawValue, 1)
        XCTAssertEqual(Proto_DeviceType(rawValue: 2), .UNRECOGNIZED(2))
        XCTAssertFalse(Proto_DeviceType.allCases.contains(.UNRECOGNIZED(2)))
    }

    func testChallengeScopeAndDeviceUsage_rawValues() {
        XCTAssertEqual(Proto_ChallengeScope.manageDevices.rawValue, 4)
        XCTAssertEqual(Proto_ChallengeScope.headlessLogin.rawValue, 3)
        XCTAssertEqual(Proto_DeviceUsage.passwordless.rawValue, 2)
    }
}
