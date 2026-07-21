// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  Signer.swift
//  SEPWebAuthn
//
//  Ports the `WebAuthnSigner` abstraction from Teleport's
//  lib/auth/touchid/api.go. The Go code uses an implicit `native` interface
//  (Register / Authenticate / FindCredentials). The spike only needs:
//
//    - create a P-256 keypair (returns id + raw public key bytes)
//    - sign a digest with the private key
//
//  Two implementations:
//    - SoftwareSigner       (Part A — CryptoKit P256, no SEP)
//    - SecureEnclaveSigner  (Part B — SecKey* + kSecAttrTokenIDSecureEnclave)

import Foundation

/// A signing primitive abstracting `native.Register` + `native.Authenticate`.
///
/// The Go `native.Register` returns a `CredentialInfo` whose `publicKeyRaw` is
/// the ANSI X9.63 representation (`0x04 || X || Y`) from
/// `SecKeyCopyExternalRepresentation`. The software signer produces the same
/// 65-byte shape so the downstream `ECDSAPublicKeyFromRaw`-equivalent parsing
/// (here done inline) works identically.
public protocol WebAuthnSigner: AnyObject {
    /// Human-readable label for log output ("software" / "sep").
    var label: String { get }

    /// Create a new P-256 keypair and return `(credentialID, publicKeyRaw)`.
    ///
    /// `credentialID` is an opaque identifier for the key — the Go path uses
    /// the key's `kSecAttrApplicationLabel` (a random 32-byte value). The
    /// spike uses a random 32-byte value; it is later emitted verbatim as the
    /// WebAuthn credential `id` (then base64url-encoded as `rawId`).
    ///
    /// `publicKeyRaw` MUST be the ANSI X9.63 form `0x04 || X(32) || Y(32)` —
    /// 65 bytes — to match `SecKeyCopyExternalRepresentation`'s output and
    /// what `darwin.ECDSAPublicKeyFromRaw` expects.
    func createKey() throws -> (credentialID: Data, publicKeyRaw: Data)

    /// Sign `digest` (32-byte SHA-256) with the private key referenced by
    /// `credentialID`. Returns the raw ECDSA signature in ASN.1 DER
    /// `SEQUENCE { r INTEGER, s INTEGER }` form — this is what
    /// `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256, ...)`
    /// returns on Apple platforms, and what Teleport's `native.Authenticate`
    /// returns to `api.go:Register` / `api.go:Login`.
    ///
    /// Note: WebAuthn/COSE ES256 signatures are *fixed-width* (r||s, 64 bytes)
    /// per FIDO2, but Teleport's `tsh mfa add --type TOUCHID` path sends DER
    /// and Teleport accepts it (the go-webauthn verifier parses both). The
    /// spike sends DER to match `api.go` byte-for-byte.
    func sign(digest: Data, credentialID: Data) throws -> Data
}

// MARK: - Errors

public enum SignerError: Error, CustomStringConvertible {
    case keyCreationFailed(String)
    case keyNotFound
    case signingFailed(String)
    case invalidPublicKey(String)

    public var description: String {
        switch self {
        case .keyCreationFailed(let m):  return "key creation failed: \(m)"
        case .keyNotFound:              return "credential not found"
        case .signingFailed(let m):     return "signing failed: \(m)"
        case .invalidPublicKey(let m):  return "invalid public key: \(m)"
        }
    }
}

// MARK: - credentialID generation (shared)

/// 32 random bytes — mirrors the Go `native.Register` path which uses
/// `kSecAttrApplicationLabel` set to a random `NSData` value. (In production
/// Teleport uses `uuid.NewString()` — a 36-char string — as the credential
/// ID; the spike uses a 32-byte random value, base64url-encoded, which is
/// equally opaque and round-trips cleanly as the WebAuthn `id`/`rawId`.)
func newCredentialID() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
    return Data(bytes)
}
