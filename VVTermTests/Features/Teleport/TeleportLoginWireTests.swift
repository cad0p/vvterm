// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportLoginWireTests.swift
//  VVTermTests
//
//  Locks in the Phase-3 login/finish wire request shape (issue #83 M4):
//  the request must carry BOTH `ssh_pub_key` (v17+ field) and `pub_key`
//  (v16-era field) so the ceremony works against the CI Teleport v16.4.0
//  server AND v17+ proxies. The v16 handler (`mfaLoginFinish` →
//  `AuthenticateSSHUserRequest.PubKey []byte json:"pub_key"`) ignores
//  `ssh_pub_key`; sending only the v17 field yields an empty subject key
//  on v16 servers.

import XCTest
@testable import VVTerm

final class TeleportLoginWireTests: XCTestCase {

    func testLoginFinishReq_carriesBothPubKeyFieldsForV16AndV17Compat() throws {
        let assertion = CredentialAssertionResponse(
            id: "aWQ",
            type: "public-key",
            rawId: "cmF3",
            response: AuthenticatorAssertionResponse(
                clientDataJSON: "Y2Rq",
                authenticatorData: "YWRhdGE",
                signature: "c2ln",
                userHandle: nil
            )
        )
        let req = LoginFinishReq(
            webauthnChallengeResponse: assertion,
            sshPubKey: Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci".utf8),
            pubKey: Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci".utf8),
            ttl: 3_600_000_000_000
        )
        let data = try JSONEncoder().encode(req)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(object["webauthn_challenge_response"], "assertion field missing")
        // v16 handler: PubKey []byte `json:"pub_key"` (lib/client/weblogin.go:181).
        let pubKey = try XCTUnwrap(object["pub_key"] as? String, "pub_key missing")
        XCTAssertEqual(
            pubKey,
            Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGeneratedKey ci".utf8).base64EncodedString(),
            "pub_key must be the base64 of the authorized_keys string (Go []byte marshaling)"
        )
        // v17 handler: UserPublicKeys.SSHPubKey `json:"ssh_pub_key"`.
        XCTAssertNotNil(object["ssh_pub_key"], "ssh_pub_key missing for v17 proxies")
        // ttl in nanoseconds (Go time.Duration).
        XCTAssertEqual(object["ttl"] as? NSNumber, NSNumber(value: 3_600_000_000_000))
    }
}
