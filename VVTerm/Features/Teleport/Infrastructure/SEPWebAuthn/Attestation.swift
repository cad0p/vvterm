// SPDX-License-Identifier: MIT
//
//  Attestation.swift
//  VVTerm
//
//  Builds the WebAuthn attestation inputs: the collected client data JSON,
//  the authenticator data, the signed message, and the COSE EC2 public key.
//
//  Every byte here is a wire contract verified by the server and pinned by
//  the committed Go fixtures:
//    - clientDataJSON is a compact three-field object in the order
//      type/challenge/origin, with the challenge base64url-encoded without
//      padding and Go's HTML-safe string escaping;
//    - authenticatorData is rpIdHash || flags || signCount, followed by the
//      attested credential data (AAGUID || credIdLen || credId || COSE key)
//      for the create ceremony only;
//    - message is authenticatorData || SHA-256(clientDataJSON), and the
//      signer signs SHA-256(message);
//    - the COSE EC2 key is canonical CBOR with x/y left-zero-padded to 32
//      bytes.
//

import Foundation
import CryptoKit

// MARK: - Ceremony

/// The two WebAuthn ceremonies.
public enum CeremonyType: String {
    case create = "webauthn.create"
    case get = "webauthn.get"
}

// MARK: - Collected client data

/// The `CollectedClientData` the authenticator signs over.
public struct CollectedClientData: Codable {
    public let type: String
    public let challenge: String
    public let origin: String

    public init(type: String, challenge: String, origin: String) {
        self.type = type
        self.challenge = challenge
        self.origin = origin
    }

    /// The compact JSON bytes the authenticator hashes.
    ///
    /// The field order and escaping mirror Go's `json.Marshal` (which enables
    /// HTML escaping): `"`/`\`/control characters are escaped, and
    /// `<`/`>`/`&`/U+2028/U+2029 are escaped as `\uXXXX`.
    public func toJSONBytes() -> Data {
        let json = "{\"type\":\"\(Self.goJSONEscaped(type))\","
            + "\"challenge\":\"\(Self.goJSONEscaped(challenge))\","
            + "\"origin\":\"\(Self.goJSONEscaped(origin))\"}"
        return Data(json.utf8)
    }

    private static func goJSONEscaped(_ value: String) -> String {
        var escaped = String.UnicodeScalarView()
        escaped.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped.append(contentsOf: "\\\"".unicodeScalars)
            case "\\": escaped.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": escaped.append(contentsOf: "\\n".unicodeScalars)
            case "\r": escaped.append(contentsOf: "\\r".unicodeScalars)
            case "\t": escaped.append(contentsOf: "\\t".unicodeScalars)
            case "\u{08}": escaped.append(contentsOf: "\\b".unicodeScalars)
            case "\u{0C}": escaped.append(contentsOf: "\\f".unicodeScalars)
            case "<": escaped.append(contentsOf: "\\u003c".unicodeScalars)
            case ">": escaped.append(contentsOf: "\\u003e".unicodeScalars)
            case "&": escaped.append(contentsOf: "\\u0026".unicodeScalars)
            case "\u{2028}": escaped.append(contentsOf: "\\u2028".unicodeScalars)
            case "\u{2029}": escaped.append(contentsOf: "\\u2029".unicodeScalars)
            default:
                if scalar.value < 0x20 {
                    escaped.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
                } else {
                    escaped.append(scalar)
                }
            }
        }
        return String(escaped)
    }
}

// MARK: - Attestation data

/// The assembled inputs for one ceremony.
public struct AttestationData {
    /// The raw clientDataJSON bytes.
    public let ccdJSON: Data
    /// The raw authenticatorData bytes.
    public let rawAuthData: Data
    /// `rawAuthData || SHA-256(ccdJSON)` — what the signer signs.
    public let message: Data
    /// `SHA-256(message)`.
    public let digest: Data
}

/// One credential's id and encoded public key.
public struct CredentialData {
    public let id: Data
    public let pubKeyCBOR: Data

    public init(id: Data, pubKeyCBOR: Data) {
        self.id = id
        self.pubKeyCBOR = pubKeyCBOR
    }
}

// MARK: - Builders

/// Builds the attestation data for a ceremony.
///
/// - Parameters:
///   - ceremony: create or get.
///   - origin: the full origin (`https://host`).
///   - rpID: the relying party id (hashed into the authenticator data).
///   - challenge: the raw server challenge (base64url-encoded into the
///     client data).
///   - cred: the credential to attest (required for `.create`, ignored for
///     `.get`).
public func makeAttestationData(
    ceremony: CeremonyType,
    origin: String,
    rpID: String,
    challenge: Data,
    cred: CredentialData?
) throws -> AttestationData {
    if ceremony == .create && cred == nil {
        throw SignerError.invalidPublicKey("the create ceremony requires a credential")
    }

    let clientData = CollectedClientData(
        type: ceremony.rawValue,
        challenge: challenge.base64URLEncodedString(),
        origin: origin
    )
    let ccdJSON = clientData.toJSONBytes()

    var authenticatorData = Data(SHA256.hash(data: Data(rpID.utf8)))
    // User Present + User Verified always; Attested credential data for
    // registration.
    var flags: UInt8 = 0x01 | 0x04
    if ceremony == .create {
        flags |= 0x40
    }
    authenticatorData.append(flags)
    // Signature counter: this client never keeps one.
    authenticatorData.append(contentsOf: [0, 0, 0, 0])

    if ceremony == .create, let cred {
        authenticatorData.append(Data(repeating: 0, count: 16)) // AAGUID
        let credentialIDLength = UInt16(clamping: cred.id.count)
        authenticatorData.append(UInt8(truncatingIfNeeded: credentialIDLength >> 8))
        authenticatorData.append(UInt8(truncatingIfNeeded: credentialIDLength & 0xff))
        authenticatorData.append(cred.id)
        authenticatorData.append(cred.pubKeyCBOR)
    }

    let clientDataHash = Data(SHA256.hash(data: ccdJSON))
    let message = authenticatorData + clientDataHash
    let digest = Data(SHA256.hash(data: message))

    return AttestationData(
        ccdJSON: ccdJSON,
        rawAuthData: authenticatorData,
        message: message,
        digest: digest
    )
}

/// Encodes a P-256 public key as the canonical COSE EC2 key CBOR.
///
/// - Parameter publicKeyRaw: the ANSI X9.63 point (`0x04 || X || Y`), with
///   coordinates up to 32 bytes (left-zero-padded here).
/// - Throws: `SignerError.invalidPublicKey` for a wrong prefix, an even
///   total length, or coordinates longer than 32 bytes.
public func coseEC2PublicKeyCBOR(publicKeyRaw: Data) throws -> Data {
    guard let prefix = publicKeyRaw.first, prefix == 0x04 else {
        throw SignerError.invalidPublicKey("expected an X9.63 uncompressed point (0x04 prefix)")
    }

    let coordinates = publicKeyRaw.dropFirst()
    guard coordinates.count % 2 == 0 else {
        throw SignerError.invalidPublicKey("expected an even number of coordinate bytes")
    }
    let coordinateLength = coordinates.count / 2
    guard coordinateLength > 0, coordinateLength <= 32 else {
        throw SignerError.invalidPublicKey("P-256 coordinates must be 1...32 bytes")
    }

    let x = Data(repeating: 0, count: 32 - coordinateLength)
        + Data(coordinates.prefix(coordinateLength))
    let y = Data(repeating: 0, count: 32 - coordinateLength)
        + Data(coordinates.suffix(coordinateLength))

    // Canonical CTAP2 CBOR sorts map keys length-first, then bytewise; the
    // five integer keys here all encode to one byte.
    return CBOR.encodeMap(items: [
        (CBOR.encodeInt(1), CBOR.encodeInt(2)),          // kty: EC2
        (CBOR.encodeInt(3), CBOR.encodeInt(-7)),         // alg: ES256
        (CBOR.encodeInt(-1), CBOR.encodeInt(1)),         // crv: P-256
        (CBOR.encodeInt(-2), CBOR.encodeByteString(x)),  // x
        (CBOR.encodeInt(-3), CBOR.encodeByteString(y)),  // y
    ])
}
