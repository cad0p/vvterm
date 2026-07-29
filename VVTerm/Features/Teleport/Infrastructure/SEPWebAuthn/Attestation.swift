// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  Attestation.swift
//  SEPWebAuthn
//
//  Ports `makeAttestationData` + `collectedClientData` from Teleport's
//  lib/auth/touchid/api.go (lines ~379-451). These are the wire-format
//  primitives shared by both Register (CreateCeremony) and Login
//  (AssertCeremony).
//
//  CRITICAL: the byte layout must match the Go path exactly. FixtureTests.swift
//  byte-compares the output against Go-generated fixtures to catch
//  transcription errors.

import Foundation
import CryptoKit

// MARK: - Ceremony type

public enum CeremonyType: String {
    /// "webauthn.create" — used in collectedClientData.type for registration.
    case create = "webauthn.create"
    /// "webauthn.get" — used in collectedClientData.type for login/assertion.
    case `get` = "webauthn.get"
}

// MARK: - WebAuthn flags (bits in the authenticatorData flags byte)
//  Mirrors protocol.Flag* from go-webauthn.
private enum Flag: UInt8 {
    case userPresent                = 0x01  // bit 0
    case userVerified               = 0x04  // bit 2
    case backupEligible             = 0x08  // bit 3
    case backupState                = 0x10  // bit 4
    case attestedCredentialData     = 0x40  // bit 6
    case extensionData              = 0x80  // bit 7
}

// MARK: - collectedClientData
//  Mirrors api.go:379-385. Note: Teleport's collectedClientData has ONLY three
//  fields (type/challenge/origin) — it omits `crossOrigin`/`topOrigin` that the
//  full W3C spec mandates. The server accepts the 3-field form (tsh produces
//  it), so the spike produces the same 3-field JSON to be byte-compatible.

/// Mirrors `collectedClientData` in api.go. Serialized as JSON with exactly
/// three keys in this order: `type`, `challenge`, `origin`. Go's
/// `encoding/json` orders fields by struct declaration order, and the
/// `challenge` is base64url-encoded without padding (RawURLEncoding).
public struct CollectedClientData: Codable {
    public let type: String
    public let challenge: String  // base64url(challengeBytes), no padding
    public let origin: String

    public init(type: String, challenge: String, origin: String) {
        self.type = type
        self.challenge = challenge
        self.origin = origin
    }

    /// Keys must appear in the order type, challenge, origin — Go's
    /// encoding/json emits struct fields in declaration order, and the JSON
    /// bytes are what's hashed (sha256) into authenticatorData's signature
    /// input. Any reordering invalidates the signature.
    ///
    /// Swift's synthesized Codable emits keys in declaration order too, but we
    /// encode the JSON manually below to make the ordering guarantee
    /// explicit and auditable (and to control the base64url encoding exactly).
    public func toJSONBytes() -> Data {
        // {"type":"...","challenge":"...","origin":"..."}
        // — no whitespace, no padding. Matches Go json.Marshal output for
        // this 3-field struct.
        let typeStr = Self.jsonEncodeString(type)
        let chalStr = Self.jsonEncodeString(challenge)
        let originStr = Self.jsonEncodeString(origin)
        let json = "{\"type\":\(typeStr),\"challenge\":\(chalStr),\"origin\":\(originStr)}"
        return Data(json.utf8)
    }

    /// Minimal JSON string encoder — escapes the required characters. Go's
    /// encoding/json escapes `<`, `>`, `&` by default (HTMLEscape); our values
    /// (ceremony string, base64url challenge, https origin) never contain
    /// these, but we match Go's behaviour for correctness if a future caller
    /// passes an unusual origin.
    private static func jsonEncodeString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"":  out += "\\\""
            case "\\":   out += "\\\\"
            case "\n":   out += "\\n"
            case "\r":   out += "\\r"
            case "\t":   out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "<":   out += "\\u003c"   // match Go HTMLEscape
            case ">":   out += "\\u003e"
            case "&":   out += "\\u0026"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - AttestationData (the makeAttestationData port)
//  Mirrors api.go:387-451. Produces (ccdJSON, rawAuthData, digest).

public struct AttestationData {
    /// JSON-encoded collectedClientData (3-field form). Emitted verbatim as
    /// `clientDataJSON` in the WebAuthn response.
    public let ccdJSON: Data

    /// The raw authenticator data bytes (rpIdHash || flags || signCount ||
    /// [attestedCredentialData]). Emitted verbatim as `authenticatorData` in
    /// assertion responses, and embedded inside the CBOR `attestationObject`
    /// for registration responses.
    public let rawAuthData: Data

    /// The concatenation rawAuthData || sha256(ccdJSON) — i.e.
    /// `authData || clientDataHash` in WebAuthn terms. This is the message
    /// the server hashes and verifies against. Signers that hash internally
    /// (e.g. CryptoKit's `signature(for: Data)` or SEP's
    /// `.ecdsaSignatureMessageX962SHA256`) sign this directly.
    public let message: Data

    /// SHA-256(message) = SHA-256(rawAuthData || sha256(ccdJSON)). This is
    /// the PRE-HASHED digest that signers using a *Digest* variant sign
    /// directly without re-hashing (e.g. SEP's
    /// `.ecdsaSignatureDigestX962SHA256`, matching authenticate.m:58).
    public let digest: Data
}

/// Credential data for registration. `id` is the credential ID (opaque
/// bytes); `pubKeyCBOR` is the CBOR-encoded COSE EC2 public key.
public struct CredentialData {
    public let id: Data
    public let pubKeyCBOR: Data

    public init(id: Data, pubKeyCBOR: Data) {
        self.id = id
        self.pubKeyCBOR = pubKeyCBOR
    }
}

/// Build authenticatorData + clientDataJSON + digest for a ceremony.
///
/// Mirrors `makeAttestationData` in api.go:387. The layout is:
///
///     authenticatorData =
///       sha256(rpID) (32)
///       || flags (1)
///       || signCount (4, big-endian, always 0)
///       || [if create: aaguid(16) || credIdLen(2 BE) || credId || pubKeyCBOR]
///
///     digest = sha256(authenticatorData || sha256(clientDataJSON))
///
/// `cred` is required for `create` and ignored for `get`.
public func makeAttestationData(
    ceremony: CeremonyType,
    origin: String,
    rpID: String,
    challenge: Data,
    cred: CredentialData?
) throws -> AttestationData {
    let isCreate = (ceremony == .create)
    if isCreate && cred == nil {
        throw SignerError.invalidPublicKey("cred required for create ceremony")
    }

    // collectedClientData — 3 fields, challenge is base64url no padding.
    let ccd = CollectedClientData(
        type: ceremony.rawValue,
        challenge: challenge.base64URLEncodedString(),
        origin: origin
    )
    let ccdJSON = ccd.toJSONBytes()

    let ccdHash = Data(SHA256.hash(data: ccdJSON))
    let rpIDHash = Data(SHA256.hash(data: Data(rpID.utf8)))

    // Flags: UP | UV (+ AT for create). Matches api.go:418-421.
    var flags: UInt8 = Flag.userPresent.rawValue | Flag.userVerified.rawValue
    if isCreate {
        flags |= Flag.attestedCredentialData.rawValue
    }

    // Assemble authenticatorData.
    var authData = Data()
    authData.append(rpIDHash)                 // 32 bytes
    authData.append(flags)                    // 1 byte
    // signCount: uint32 BE, always 0 (api.go:423).
    authData.append(contentsOf: [0, 0, 0, 0])
    if isCreate, let cred = cred {
        authData.append(contentsOf: [UInt8](repeating: 0, count: 16))  // aaguid (16 zero bytes)
        // credentialIdLength: uint16 BE
        let credIDLen = UInt16(cred.id.count)
        authData.append(UInt8(credIDLen >> 8))
        authData.append(UInt8(credIDLen & 0xff))
        authData.append(cred.id)
        authData.append(cred.pubKeyCBOR)
    }

    // The WebAuthn message = authData || clientDataHash, where
    // clientDataHash = sha256(ccdJSON). The server computes the same and
    // verifies the signature over sha256(message). Signers that hash
    // internally (CryptoKit signature(for: Data), SEP Message variant) sign
    // `message` directly; signers that take a pre-hashed digest (SEP Digest
    // variant) sign `digest = sha256(message)`.
    var message = Data()
    message.append(authData)
    message.append(ccdHash)
    let digest = Data(SHA256.hash(data: message))

    return AttestationData(
        ccdJSON: ccdJSON,
        rawAuthData: authData,
        message: message,
        digest: digest
    )
}

// MARK: - COSE public key CBOR

/// Build the COSE EC2 P-256 public key in CBOR, matching the Go
/// `webauthncose.EC2PublicKeyData` marshal in api.go:284-307.
///
/// The COSE_Key is a CBOR map with integer keys:
///
///     { 1: 2, 3: -7, -1: 1, -2: <32-byte x>, -3: <32-byte y> }
///
/// where:
///   - 1 (kty) = 2 (EllipticKey)
///   - 3 (alg) = -7 (ES256)
///   - -1 (crv) = 1 (P-256)
///   - -2 (x)   = 32-byte big-endian X (zero-padded if needed)
///   - -3 (y)   = 32-byte big-endian Y (zero-padded if needed)
///
/// `publicKeyRaw` is the ANSI X9.63 form: `0x04 || X(32) || Y(32)` (65 bytes).
public func coseEC2PublicKeyCBOR(publicKeyRaw: Data) throws -> Data {
    // Parse the ANSI X9.63 form (0x04 || X || Y). Mirrors
    // darwin.ECDSAPublicKeyFromRaw in lib/darwin/pub_key.go.
    guard publicKeyRaw.count >= 3 else {
        throw SignerError.invalidPublicKey(
            "public key representation too small (\(publicKeyRaw.count) bytes)")
    }
    guard publicKeyRaw.count.isMultiple(of: 2) == false else {
        // 0x4+keyLen+keyLen is always odd.
        throw SignerError.invalidPublicKey(
            "public key representation has unexpected length (\(publicKeyRaw.count) bytes)")
    }
    guard publicKeyRaw[0] == 0x04 else {
        throw SignerError.invalidPublicKey(
            "public key representation starts with unexpected byte (0x\(String(publicKeyRaw[0], radix: 16)) vs 0x4)")
    }

    let body = publicKeyRaw.dropFirst()  // skip 0x04
    let coordLen = body.count / 2
    var x = Data(body.prefix(coordLen))
    var y = Data(body.suffix(coordLen))

    // api.go:294-296 — x and y must be exactly 32 bytes (FillBytes semantics).
    // The SEP / CryptoKit always produces 32-byte coords, but defensively
    // zero-pad on the left if somehow shorter.
    let pad: (inout Data) throws -> Void = { d in
        if d.count < 32 {
            d = Data(repeating: 0, count: 32 - d.count) + d
        } else if d.count > 32 {
            throw SignerError.invalidPublicKey(
                "coordinate too long (\(d.count) bytes, expected 32)")
        }
    }
    try pad(&x)
    try pad(&y)

    // CBOR-encode the map. Use the canonical CTAP2 form (short keys, sorted).
    // See COSEKey.swift for the encoder.
    return CBOR.encodeMap(items: [
        (CBOR.encodeInt(1),  CBOR.encodeUint(2)),   // kty = 2 (EC2)
        (CBOR.encodeInt(3),  CBOR.encodeInt(-7)),    // alg = -7 (ES256)
        (CBOR.encodeInt(-1), CBOR.encodeUint(1)),    // crv = 1 (P-256)
        (CBOR.encodeInt(-2), CBOR.encodeByteString(x)),
        (CBOR.encodeInt(-3), CBOR.encodeByteString(y)),
    ])
}
