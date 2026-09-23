// SPDX-License-Identifier: MIT
//
//  WebAuthn.swift
//  VVTerm
//
//  Assembles the WebAuthn registration and assertion responses the Teleport
//  server consumes.
//
//  The response JSON mirrors Go's `webauthntypes` structs: a public-key
//  credential object (`id`, `type`, `rawId`) with a ceremony-specific
//  `response` object. Every binary field is base64url without padding, and
//  `id`/`rawId` carry the same credential id bytes.
//
//  The attestation object is canonical CTAP2 CBOR:
//    { "fmt": "packed", "attStmt": { "alg": -7, "sig": <DER> },
//      "authData": <bytes> }
//  with the map keys in length-first order.
//

import Foundation

// MARK: - Response types

/// The public-key credential identity shared by both ceremonies.
public struct PublicKeyCredential: Codable {
    public let id: String
    public let type: String
    public let rawId: String

    public init(id: String, type: String, rawId: String) {
        self.id = id
        self.type = type
        self.rawId = rawId
    }
}

/// The base authenticator response carrying the raw client data JSON.
public struct AuthenticatorResponse: Codable {
    public let clientDataJSON: String

    public init(clientDataJSON: String) {
        self.clientDataJSON = clientDataJSON
    }
}

/// The registration ceremony's authenticator response.
public struct AuthenticatorAttestationResponse: Codable {
    public let clientDataJSON: String
    public let attestationObject: String

    public init(clientDataJSON: String, attestationObject: String) {
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
    }
}

/// The login ceremony's authenticator response.
public struct AuthenticatorAssertionResponse: Codable {
    public let clientDataJSON: String
    public let authenticatorData: String
    public let signature: String
    /// Omitted when nil; an empty handle is a present empty string.
    public let userHandle: String?

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

/// The full registration response.
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

/// The full login response.
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

// MARK: - Builder

/// Builds the registration and assertion responses.
public enum WebAuthn {

    /// Builds a registration response, signing the create-ceremony message
    /// with `signer`.
    public static func register(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        publicKeyRaw: Data,
        signer: any WebAuthnSigner
    ) throws -> CredentialCreationResponse {
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: publicKeyRaw)
        let attestationData = try makeAttestationData(
            ceremony: .create,
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            cred: CredentialData(id: credentialID, pubKeyCBOR: pubKeyCBOR)
        )
        let signature = try signer.sign(
            message: attestationData.message,
            credentialID: credentialID
        )
        let attestationObject = buildAttestationObjectCBOR(
            authData: attestationData.rawAuthData,
            signature: signature
        )

        return CredentialCreationResponse(
            id: credentialID.base64URLEncodedString(),
            type: "public-key",
            rawId: credentialID.base64URLEncodedString(),
            response: AuthenticatorAttestationResponse(
                clientDataJSON: attestationData.ccdJSON.base64URLEncodedString(),
                attestationObject: attestationObject.base64URLEncodedString()
            )
        )
    }

    /// Builds an assertion response, signing the get-ceremony message with
    /// `signer`.
    public static func login(
        origin: String,
        rpID: String,
        challenge: Data,
        credentialID: Data,
        userHandle: Data?,
        signer: any WebAuthnSigner
    ) throws -> CredentialAssertionResponse {
        let attestationData = try makeAttestationData(
            ceremony: .get,
            origin: origin,
            rpID: rpID,
            challenge: challenge,
            cred: nil
        )
        let signature = try signer.sign(
            message: attestationData.message,
            credentialID: credentialID
        )

        return CredentialAssertionResponse(
            id: credentialID.base64URLEncodedString(),
            type: "public-key",
            rawId: credentialID.base64URLEncodedString(),
            response: AuthenticatorAssertionResponse(
                clientDataJSON: attestationData.ccdJSON.base64URLEncodedString(),
                authenticatorData: attestationData.rawAuthData.base64URLEncodedString(),
                signature: signature.base64URLEncodedString(),
                userHandle: userHandle?.base64URLEncodedString()
            )
        )
    }

    /// Encodes the `packed` attestation object CBOR.
    public static func buildAttestationObjectCBOR(authData: Data, signature: Data) -> Data {
        let attestationStatement = CBOR.encodeMap(items: [
            (CBOR.encodeString("alg"), CBOR.encodeInt(-7)),
            (CBOR.encodeString("sig"), CBOR.encodeByteString(signature)),
        ])
        return CBOR.encodeMap(items: [
            (CBOR.encodeString("fmt"), CBOR.encodeString("packed")),
            (CBOR.encodeString("attStmt"), attestationStatement),
            (CBOR.encodeString("authData"), CBOR.encodeByteString(authData)),
        ])
    }
}
