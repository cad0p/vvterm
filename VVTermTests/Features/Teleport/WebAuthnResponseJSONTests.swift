// SPDX-License-Identifier: MIT
//
//  WebAuthnResponseJSONTests.swift
//  VVTermTests
//
//  Pins the JSON that `WebAuthn.register` / `WebAuthn.login` put on the wire
//  (the payloads POSTed to /webapi/mfa/devices and /webapi/mfa/login/finish).
//  Teleport decodes these with Go `encoding/json` against the
//  lib/auth/webauthntypes structs, so the field names, the `"public-key"`
//  type, and the base64url-no-padding encoding of `id`/`rawId`/blobs are the
//  contract.
//
//  Uses a fixed signer so the assertions are deterministic.

import XCTest
@testable import VVTerm

/// A deterministic `WebAuthnSigner` for JSON-shape tests.
private final class FixedWebAuthnSigner: WebAuthnSigner {
    let label = "fixed"
    let credentialID: Data
    let publicKeyRaw: Data
    let signature: Data

    init(credentialID: Data, publicKeyRaw: Data, signature: Data) {
        self.credentialID = credentialID
        self.publicKeyRaw = publicKeyRaw
        self.signature = signature
    }

    func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        (credentialID, publicKeyRaw)
    }

    func sign(message: Data, credentialID: Data) throws -> Data {
        signature
    }
}

final class WebAuthnResponseJSONTests: XCTestCase {

    private static let origin = "https://teleport.pcad.it"
    private static let rpID = "teleport.pcad.it"
    private static let challenge = Data([1, 2, 3])
    /// Bytes whose base64 is `+/+/` and base64url is `-_-_` — pins the
    /// no-padding URL-safe alphabet.
    private static let credentialID = Data([0xfb, 0xff, 0xbf])
    /// A structurally valid X9.63 P-256 point (0x04 || 64 bytes); the COSE
    /// encoder only validates the shape.
    private static let publicKeyRaw = Data([0x04] + Array(repeating: 0x11, count: 64))
    private static let signature = Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02])

    private func makeSigner() -> FixedWebAuthnSigner {
        FixedWebAuthnSigner(
            credentialID: Self.credentialID,
            publicKeyRaw: Self.publicKeyRaw,
            signature: Self.signature
        )
    }

    func testBase64URLEncoding_differsFromStandardBase64() {
        XCTAssertEqual(Self.credentialID.base64EncodedString(), "+/+/")
        XCTAssertEqual(Self.credentialID.base64URLEncodedString(), "-_-_")
        XCTAssertFalse(Self.credentialID.base64URLEncodedString().contains("="))
        XCTAssertEqual(Data(base64URLEncoded: "-_-_"), Self.credentialID)
        XCTAssertEqual(Data(base64URLEncoded: "+/+/"), Self.credentialID, "decoder tolerates std base64")
    }

    func testRegisterJSON_pinsTheCredentialCreationFields() throws {
        let response = try WebAuthn.register(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            publicKeyRaw: Self.publicKeyRaw,
            signer: makeSigner()
        )
        let json = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["id", "type", "rawId", "response"])
        XCTAssertEqual(object["type"] as? String, "public-key")
        XCTAssertEqual(object["id"] as? String, "-_-_")
        XCTAssertEqual(object["rawId"] as? String, "-_-_")
        XCTAssertFalse((object["id"] as? String ?? "").contains("="), "no padding")

        let inner = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(Set(inner.keys), ["clientDataJSON", "attestationObject"])

        let ccdJSONString = try XCTUnwrap(inner["clientDataJSON"] as? String)
        XCTAssertFalse(ccdJSONString.contains("="), "no padding")
        let ccdJSON = try XCTUnwrap(Data(base64URLEncoded: ccdJSONString))
        XCTAssertEqual(
            String(data: ccdJSON, encoding: .utf8),
            #"{"type":"webauthn.create","challenge":"AQID","origin":"https://teleport.pcad.it"}"#
        )

        let attObjString = try XCTUnwrap(inner["attestationObject"] as? String)
        XCTAssertFalse(attObjString.contains("="), "no padding")
        let attObj = try XCTUnwrap(Data(base64URLEncoded: attObjString))
        // The committed signature is injected verbatim; the authData is the
        // create-ceremony authenticatorData.
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: Self.publicKeyRaw)
        let attData = try makeAttestationData(
            ceremony: .create,
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            cred: CredentialData(id: Self.credentialID, pubKeyCBOR: pubKeyCBOR)
        )
        XCTAssertEqual(
            attObj,
            WebAuthn.buildAttestationObjectCBOR(
                authData: attData.rawAuthData,
                signature: Self.signature
            )
        )
    }

    func testLoginJSON_pinsTheAssertionFields() throws {
        let response = try WebAuthn.login(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            userHandle: Data([1, 2, 3]),
            signer: makeSigner()
        )
        let json = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["id", "type", "rawId", "response"])
        XCTAssertEqual(object["type"] as? String, "public-key")
        XCTAssertEqual(object["id"] as? String, "-_-_")
        XCTAssertEqual(object["rawId"] as? String, "-_-_")

        let inner = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(
            Set(inner.keys),
            ["clientDataJSON", "authenticatorData", "signature", "userHandle"]
        )
        XCTAssertEqual(inner["userHandle"] as? String, "AQID")

        let ccdJSONString = try XCTUnwrap(inner["clientDataJSON"] as? String)
        let ccdJSON = try XCTUnwrap(Data(base64URLEncoded: ccdJSONString))
        XCTAssertEqual(
            String(data: ccdJSON, encoding: .utf8),
            #"{"type":"webauthn.get","challenge":"AQID","origin":"https://teleport.pcad.it"}"#
        )

        let authDataString = try XCTUnwrap(inner["authenticatorData"] as? String)
        XCTAssertFalse(authDataString.contains("="), "no padding")
        XCTAssertEqual(
            Data(base64URLEncoded: authDataString),
            try makeAttestationData(
                ceremony: .get,
                origin: Self.origin,
                rpID: Self.rpID,
                challenge: Self.challenge,
                cred: nil
            ).rawAuthData
        )
        XCTAssertEqual(inner["signature"] as? String, Self.signature.base64URLEncodedString())
    }

    func testLoginJSON_userHandleNilIsOmittedAndEmptyIsEmptyString() throws {
        // nil userHandle -> Go `omitempty`-style absence (JSONEncoder omits a
        // nil Optional).
        let nilHandle = try WebAuthn.login(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            userHandle: nil,
            signer: makeSigner()
        )
        let nilObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(nilHandle)) as? [String: Any]
        )
        let nilInner = try XCTUnwrap(nilObject["response"] as? [String: Any])
        XCTAssertNil(nilInner["userHandle"], "nil userHandle must be omitted")

        // An empty (non-nil) handle is a present empty string. Go's
        // `omitempty` omits empty slices too, but the pinned Swift shape
        // (nil omitted, empty Data() present as "") is what the server
        // accepts either way.
        let emptyHandle = try WebAuthn.login(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            userHandle: Data(),
            signer: makeSigner()
        )
        let emptyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(emptyHandle)) as? [String: Any]
        )
        let emptyInner = try XCTUnwrap(emptyObject["response"] as? [String: Any])
        XCTAssertEqual(emptyInner["userHandle"] as? String, "")
    }

    func testResponses_roundTripThroughCodable() throws {
        let creation = try WebAuthn.register(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            publicKeyRaw: Self.publicKeyRaw,
            signer: makeSigner()
        )
        let decodedCreation = try JSONDecoder().decode(
            CredentialCreationResponse.self,
            from: JSONEncoder().encode(creation)
        )
        XCTAssertEqual(decodedCreation.id, creation.id)
        XCTAssertEqual(decodedCreation.type, creation.type)
        XCTAssertEqual(decodedCreation.rawId, creation.rawId)
        XCTAssertEqual(
            decodedCreation.response.clientDataJSON,
            creation.response.clientDataJSON
        )
        XCTAssertEqual(
            decodedCreation.response.attestationObject,
            creation.response.attestationObject
        )

        let assertion = try WebAuthn.login(
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            credentialID: Self.credentialID,
            userHandle: Data([9]),
            signer: makeSigner()
        )
        let decodedAssertion = try JSONDecoder().decode(
            CredentialAssertionResponse.self,
            from: JSONEncoder().encode(assertion)
        )
        XCTAssertEqual(decodedAssertion.id, assertion.id)
        XCTAssertEqual(decodedAssertion.response.signature, assertion.response.signature)
        XCTAssertEqual(decodedAssertion.response.userHandle, assertion.response.userHandle)
    }

    /// Go's `encoding/json` (with its default HTML escaping) is what hashed
    /// the `clientDataJSON`, so the Swift encoder must escape `<`, `>`, `&`
    /// the same way and keep the field order. A reordered or unescaped
    /// payload produces a different hash and the server rejects the ceremony.
    func testCollectedClientData_escapesGoHTMLCharactersAndKeepsFieldOrder() {
        let ccd = CollectedClientData(
            type: CeremonyType.create.rawValue,
            challenge: "AQID",
            origin: "https://a<b>c&d.example"
        )
        let json = ccd.toJSONBytes()
        let text = String(data: json, encoding: .utf8) ?? ""

        XCTAssertEqual(
            text,
            #"{"type":"webauthn.create","challenge":"AQID","origin":"https://a\u003cb\u003ec\u0026d.example"}"#
        )
        XCTAssertFalse(text.contains("<"), "a raw `<` must be escaped")
        XCTAssertFalse(text.contains(">"), "a raw `>` must be escaped")
        XCTAssertFalse(text.contains("&"), "a raw `&` must be escaped")

        // Field order is part of the hash: type, then challenge, then origin.
        let typeIndex = try? XCTUnwrap(text.range(of: "\"type\"")?.lowerBound)
        let challengeIndex = try? XCTUnwrap(text.range(of: "\"challenge\"")?.lowerBound)
        let originIndex = try? XCTUnwrap(text.range(of: "\"origin\"")?.lowerBound)
        if let typeIndex, let challengeIndex, let originIndex {
            XCTAssertLessThan(typeIndex, challengeIndex)
            XCTAssertLessThan(challengeIndex, originIndex)
        } else {
            XCTFail("the clientDataJSON must carry all three keys: \(text)")
        }
    }

    /// The COSE EC2 encoder rejects malformed X9.63 inputs rather than
    /// emitting a key the server cannot verify.
    func testCOSEKey_rejectsMalformedPublicKeys() {
        func assertRejected(_ raw: Data, _ label: String) {
            do {
                _ = try coseEC2PublicKeyCBOR(publicKeyRaw: raw)
                XCTFail("\(label) must be rejected")
            } catch let error as SignerError {
                guard case .invalidPublicKey = error else {
                    return XCTFail("\(label): expected .invalidPublicKey, got \(error)")
                }
            } catch {
                XCTFail("\(label): expected SignerError, got \(error)")
            }
        }

        assertRejected(Data(), "an empty representation")
        assertRejected(Data([0x04, 0x01]), "an even-length representation")
        assertRejected(
            Data([0x05] + Array(repeating: 0x11, count: 64)),
            "a representation that does not start with 0x04"
        )
        assertRejected(
            Data([0x04] + Array(repeating: 0x11, count: 66)),
            "a representation with 33-byte coordinates"
        )

        // A create ceremony without credential data is a programming error.
        do {
            _ = try makeAttestationData(
                ceremony: .create,
                origin: Self.origin,
                rpID: Self.rpID,
                challenge: Self.challenge,
                cred: nil
            )
            XCTFail("a create ceremony without credential data must be rejected")
        } catch let error as SignerError {
            guard case .invalidPublicKey = error else {
                return XCTFail("expected .invalidPublicKey, got \(error)")
            }
        } catch {
            XCTFail("expected SignerError, got \(error)")
        }
    }
}
