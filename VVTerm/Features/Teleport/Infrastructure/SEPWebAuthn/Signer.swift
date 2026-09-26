// SPDX-License-Identifier: MIT
//
//  Signer.swift
//  VVTerm
//
//  The signer abstraction shared by the WebAuthn builder and the Secure
//  Enclave key lifecycle.
//
//  A signer owns a P-256 key and produces two things the WebAuthn builder
//  needs: the public key in ANSI X9.63 form (`0x04 || X || Y`) and DER
//  ECDSA signatures over `SHA-256(message)`. The server verifies the
//  signature against the public key it registered, so both the key encoding
//  and the single-hash convention are wire contracts.
//

import Foundation
import Security

/// A WebAuthn credential signer.
public protocol WebAuthnSigner: AnyObject {
    /// A short human-readable label for diagnostics (`sep`, `software`, ...).
    var label: String { get }

    /// Creates a fresh P-256 credential.
    ///
    /// - Returns: the credential id and the public key in X9.63 form
    ///   (`0x04 || X(32) || Y(32)`, 65 bytes).
    func createKey() throws -> (credentialID: Data, publicKeyRaw: Data)

    /// Signs `SHA-256(message)` with the credential's private key.
    ///
    /// - Returns: a DER-encoded ECDSA signature (`SEQUENCE { r, s }`).
    func sign(message: Data, credentialID: Data) throws -> Data
}

/// Errors surfaced by the signer implementations.
///
/// `LocalizedError` so `error.localizedDescription` carries the wrapped
/// system message (the login coordinator keeps a string fallback over those
/// substrings for any error it cannot classify more precisely).
public enum SignerError: Error, LocalizedError, CustomStringConvertible {
    case keyCreationFailed(String)
    case keyNotFound
    case signingFailed(String)
    /// A signing failure whose underlying `CFError` was a Security-framework
    /// status (`NSOSStatusErrorDomain`).
    ///
    /// The biometric prompt here is driven by `SecKeyCreateSignature` under a
    /// `[.privateKeyUsage, .biometryAny]` access control, so a cancelled /
    /// locked-out prompt surfaces as `errSecUserCanceled` / `errSecAuthFailed`
    /// — NOT as an `LAError`. The status is carried so the coordinator can
    /// classify locale-independently; `description` keeps the frozen
    /// `"signing failed: \(message)"` shape so the string fallback still works.
    case biometricSigningFailed(String, OSStatus)
    case invalidPublicKey(String)

    public var description: String {
        switch self {
        case .keyCreationFailed(let message):
            return "key creation failed: \(message)"
        case .keyNotFound:
            return "credential not found"
        case .signingFailed(let message):
            return "signing failed: \(message)"
        case .biometricSigningFailed(let message, _):
            return "signing failed: \(message)"
        case .invalidPublicKey(let message):
            return "invalid public key: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Generates a fresh 32-byte credential id.
///
/// `precondition` on RNG failure: a credential id that silently degrades to
/// zeros would make two devices collide.
func newCredentialID() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed with OSStatus \(status)")
    return Data(bytes)
}
