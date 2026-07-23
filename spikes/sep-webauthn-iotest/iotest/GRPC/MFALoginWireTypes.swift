// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  MFALoginWireTypes.swift
//  iotest
//
//  Session 1.10 Phase 3 — the HTTP wire types for /webapi/mfa/login/begin
//  and /webapi/mfa/login/finish. Copied verbatim from the 1.6b
//  sep-biometry-iotest app (SEPBiometryTestRunner.swift:284-352) so the
//  Phase 3 login flow is byte-identical to 1.6b's proven path.
//
//  These are JSON wire types (not protobuf) — the login flow uses the HTTP
//  webapi, not gRPC.
//

import Foundation

// MARK: - login/begin response

struct LoginBeginResponse: Decodable {
    let webauthnChallenge: WebauthnAssertion?
    enum CodingKeys: String, CodingKey {
        case webauthnChallenge = "webauthn_challenge"
    }
    struct WebauthnAssertion: Decodable {
        let publicKey: PublicKey
        struct PublicKey: Decodable {
            let challenge: String
            let rpId: String?
            enum CodingKeys: String, CodingKey {
                case challenge
                case rpId = "rpId"
            }
        }
    }
}

// MARK: - login/finish response

struct LoginFinishResponse: Decodable {
    let cert: String?
    let hostSigners: [HostSigner]?
    enum CodingKeys: String, CodingKey {
        case cert
        case hostSigners = "host_signers"
    }
    struct HostSigner: Decodable {
        let domainName: String
        let checkingKeys: [String]
        enum CodingKeys: String, CodingKey {
            case domainName = "domain_name"
            case checkingKeys = "checking_keys"
        }
    }
}

// MARK: - login/finish request

struct LoginFinishReq: Encodable {
    let webauthnChallengeResponse: CredentialAssertionResponse
    let sshPubKey: Data
    let ttl: Int64
    enum CodingKeys: String, CodingKey {
        case webauthnChallengeResponse = "webauthn_challenge_response"
        case sshPubKey = "ssh_pub_key"
        case ttl
    }
}
