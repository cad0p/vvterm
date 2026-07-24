// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  WebAuthn.swift
//  SEPWebAuthn
//
//  Ports `Register` and `Login` from Teleport's lib/auth/touchid/api.go.
//  Builds the WebAuthn attestation/assertion objects by composing
//  makeAttestationData + the signer + canonical CBOR.

import Foundation
import CryptoKit

// MARK: - WebAuthn responses (wire types)
//  Mirror lib/auth/webauthntypes/webauthn.go. Field names match the JSON
//  tags exactly because Teleport decodes these with encoding/json.

/// `PublicKeyCredential.id` + `rawId`. Shared by registration and assertion
/// responses. `id` is the credential ID as a base64url string; `rawId` is the
/// same bytes as URLEncodedBase64 (base64url no padding).
public struct PublicKeyCredential: Codable {
    public let id: String
    public let type: String
    public let rawId: String  // base64url

    public init(id: String, type: String, rawId: String) {
        self.id = id
        self.type = type
        self.rawId = rawId
    }
}

/// `AuthenticatorResponse` — just `clientDataJSON` (base64url).
public struct AuthenticatorResponse: Codable {
    public let clientDataJSON: String  // base64url

    public init(clientDataJSON: String) {
        self.clientDataJSON = clientDataJSON
    }
}

/// `AuthenticatorAttestationResponse` — adds `attestationObject`.
public struct AuthenticatorAttestationResponse: Codable {
    public let clientDataJSON: String      // base64url
    public let attestationObject: String   // base64url

    public init(clientDataJSON: String, attestationObject: String) {
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
    }
}

/// `AuthenticatorAssertionResponse` — adds `authenticatorData`, `signature`,
/// `userHandle`.
public struct AuthenticatorAssertionResponse: Codable {
    public let clientDataJSON: String      // base64url
    public let authenticatorData: String  // base64url
    public let signature: String          // base64url
    public let userHandle: String?        // base64url, omit if nil

    public init(
        clientDataJSON: String,
        authenticatorData: String,
        signature: String,
        userHandle: String?
    ) {
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// `CredentialCreationResponse` — the registration reply.
/// Mirrors wantypes.CredentialCreationResponse.
public struct CredentialCreationResponse: Codable {
    public let id: String
    public let type: String
    public let rawId: String
    public let response: AuthenticatorAttestationResponse

    public init(
        id: String,
        type: String,
        rawId: String,
        response: AuthenticatorAttestationResponse
    ) {
        self.id = id
        self.type = type
        self.rawId = rawId
        self.response = response
    }
}

/// `CredentialAssertionResponse` — the login/assertion reply.
/// Mirrors wantypes.CredentialAssertionResponse.
public struct CredentialAssertionResponse: Codable {
    public let id: String
    public let type: String
    public let rawId: String
    public let response: AuthenticatorAssertionResponse

    public init(
        id: String,
        type: String,
        rawId: String,
        response: AuthenticatorAssertionResponse
    ) {
        self.id = id
        self.type = type
        self.rawId = rawId
        self.response = response
    }
}

// MARK: - WebAuthn builder
//  Composes makeAttestationData + the signer, mirroring api.go:Register and
//  api.go:Login. The signer is injected so the same builder works for the
//  software (Part A) and SEP (Part B) signers.

public enum WebAuthn {
    /// Build a registration response (api.go:Register).
    ///
    /// - Parameters:
    ///   - origin: e.g. "https://teleport.pcad.it"
    ///   - rpID: e.g. "teleport.pcad.it"
    ///   - challenge: server-provided challenge bytes
    ///   - credentialID: the opaque credential identifier bytes (what the
    ///     signer uses as its lookup key). On the wire this becomes the
    ///     base64url-encoded `id`/`rawId`. In api.go this is a string
    ///     (uuid.NewString()); the spike uses 32 random bytes. Either is
    ///     opaque to WebAuthn — the server stores whatever the client sends.
    ///   - publicKeyRaw: ANSI X9.63 form (0x04 || X(32) || Y(32)), from
    ///     SecKeyCopyExternalRepresentation / CryptoKit x963Representation
    ///   - signer: the WebAuthnSigner (software or SEP)
    /// - Returns: CredentialCreationResponse ready to JSON-encode and POST to
    ///   /webapi/mfa/devices.
    public static func register(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        publicKeyRaw: Data,
        signer: WebAuthnSigner
    ) throws -> CredentialCreationResponse {
        // Build the COSE EC2 public key CBOR.
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: publicKeyRaw)

        // The credential ID is embedded in authenticatorData as raw bytes.
        // (api.go uses []byte(credentialID) where credentialID is a string —
        // same bytes, different source type.)
        let attData = try makeAttestationData(
            ceremony: .create,
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            cred: CredentialData(
                id: credentialID,
                pubKeyCBOR: pubKeyCBOR
            )
        )

        // Sign the message (authData || clientDataHash). Each signer hashes
        // it exactly once before signing — see WebAuthnSigner.sign.
        let sig = try signer.sign(
            message: attData.message,
            credentialID: credentialID
        )

        // Assemble the attestation object via the shared helper (tested
        // separately by FixtureTests).
        let attObj = Self.buildAttestationObjectCBOR(
            authData: attData.rawAuthData,
            signature: sig
        )

        // The wire `id` is the credential ID as a base64url string; `rawId`
        // is the same bytes base64url-encoded (URLEncodedBase64 in Go).
        // For a string credential ID (like api.go's UUID), the "bytes" are
        // the UTF-8 encoding of that string. For the spike's raw-bytes ID,
        // the bytes ARE the ID — `id` and `rawId` carry the same content,
        // just `id` as a decoded string and `rawId` as base64url.
        let idB64url = credentialID.base64URLEncodedString()
        // `id` (decoded string) — for a random 32-byte ID this is
        // non-printable, but WebAuthn treats `id` as opaque; Teleport stores
        // whatever is sent. api.go sets `id` = the string credentialID. We
        // mirror by sending the base64url form as the `id` string (matching
        // what a spec-compliant client does for non-UTF8 credential IDs).

        return CredentialCreationResponse(
            id: idB64url,
            type: "public-key",
            rawId: idB64url,
            response: AuthenticatorAttestationResponse(
                clientDataJSON: attData.ccdJSON.base64URLEncodedString(),
                attestationObject: attObj.base64URLEncodedString()
            )
        )
    }

    /// Build the attestation object CBOR bytes for a registration.
    ///
    /// Exposed for testing (FixtureTests byte-compares this against the
    /// Go-generated fixture). The signature is passed in so the test can
    /// use the deterministic Go-fixture signature.
    ///
    /// Layout (canonical CTAP2 CBOR — length-first key sort):
    ///   { "fmt": "packed",
    ///     "attStmt": { "alg": -7, "sig": <bytes> },
    ///     "authData": <bytes> }
    ///
    /// Canonical key order:
    ///   outer: fmt(3 bytes) < attStmt(7 bytes) < authData(8 bytes)
    ///   inner: alg(3 bytes) < sig(3 bytes)   [bytewise tiebreak]
    public static func buildAttestationObjectCBOR(
        authData: Data,
        signature: Data
    ) -> Data {
        let attStmtMap = CBOR.encodeMap(items: [
            (CBOR.encodeString("alg"), CBOR.encodeInt(-7)),
            (CBOR.encodeString("sig"), CBOR.encodeByteString(signature)),
        ])
        return CBOR.encodeMap(items: [
            (CBOR.encodeString("fmt"),      CBOR.encodeString("packed")),
            (CBOR.encodeString("attStmt"),  attStmtMap),
            (CBOR.encodeString("authData"), CBOR.encodeByteString(authData)),
        ])
    }

    /// Build an assertion response (api.go:Login).
    ///
    /// - Parameters:
    ///   - origin: e.g. "https://teleport.pcad.it"
    ///   - rpID: e.g. "teleport.pcad.it"
    ///   - challenge: server-provided challenge bytes (from
    ///     /webapi/mfa/login/begin → webauthn_challenge.publicKey.challenge)
    ///   - credentialID: the opaque credential identifier bytes (what the
    ///     signer uses as its lookup key — must match what was passed to
    ///     register)
    ///   - userHandle: optional user handle bytes (from the credential, if
    ///     known; Teleport returns this from FindCredentials — for the spike
    ///     we pass nil since passwordless logins don't echo it back)
    ///   - signer: the WebAuthnSigner (software or SEP)
    /// - Returns: CredentialAssertionResponse ready to JSON-encode and POST
    ///   to /webapi/mfa/login/finish.
    public static func login(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        userHandle: Data?,
        signer: WebAuthnSigner
    ) throws -> CredentialAssertionResponse {
        // Build authenticatorData + clientDataJSON + digest (no cred for get).
        let attData = try makeAttestationData(
            ceremony: .get,
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            cred: nil
        )

        let sig = try signer.sign(
            message: attData.message,
            credentialID: credentialID
        )

        let idB64url = credentialID.base64URLEncodedString()

        return CredentialAssertionResponse(
            id: idB64url,
            type: "public-key",
            rawId: idB64url,
            response: AuthenticatorAssertionResponse(
                clientDataJSON: attData.ccdJSON.base64URLEncodedString(),
                authenticatorData: attData.rawAuthData.base64URLEncodedString(),
                signature: sig.base64URLEncodedString(),
                userHandle: userHandle?.base64URLEncodedString()
            )
        )
    }
}
