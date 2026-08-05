// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SoftwareSigner.swift
//  SEPWebAuthn
//
//  Part A signer — pure software P-256 via SecKey (no Secure Enclave, no
//  biometry, no codesigning). Runs on any platform with Security (macOS 10.12+,
//  iOS 10+). On the `macos-14` GitHub Actions runner this builds and signs
//  without entitlements.
//
//  Conforms to `TeleportSEPSigning` (= `WebAuthnSigner & SEPKeySigning &
//  AnyObject`), so it can be injected anywhere a real `SecureEnclaveSigner`
//  would be — the bootstrap, registration, and login coordinators, plus the
//  `TeleportKeyRing`. This is the CI integration-test seam (issue #83 M4):
//  the integration test drives the real Phase-2 registration + Phase-3
//  passwordless ceremonies against a real Teleport cluster with this signer,
//  exactly like Teleport's own e2e tests use software WebAuthn keys.
//
//  Keys are held in-memory in a dictionary keyed by the credential ID
//  (no persistence — a fresh instance per app run; the test creates one
//  instance and shares it across the registration + login coordinators).
//  The wire output is identical to `SecureEnclaveSigner`: ANSI X9.63 public
//  keys (0x04 || X || Y) and DER-encoded ECDSA signatures over
//  SHA-256(message).

import Foundation
import Security
import CryptoKit

/// Software P-256 signer. Holds keys in-memory in a dictionary keyed by the
/// credential ID. The credential ID is a random 32-byte value generated at
/// `createKey` time (no persistence — the spike re-creates per run).
public final class SoftwareSigner: WebAuthnSigner {
    public let label = "software"

    /// The credential ID → SecKey map (mirrors `SecureEnclaveSigner.keys`).
    /// Populated by `createKey(credentialID:)`; `loadKey` returns the cached
    /// SecKey (or nil if the key was never created, mirroring the real
    /// signer's errSecItemNotFound → nil behavior).
    private var keys: [Data: SecKey] = [:]
    private let queue = DispatchQueue(label: "sep-webauthn.software-signer")

    public init() {}

    // MARK: - WebAuthnSigner (builder-facing)

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let credentialID = newCredentialID()
        let secKey = try createKey(credentialID: credentialID)

        // Extract the public key in ANSI X9.63 form (0x04 || X || Y, 65
        // bytes) — the same shape `SecureEnclaveSigner` produces.
        guard let publicKey = SecKeyCopyPublicKey(secKey) else {
            throw SignerError.keyCreationFailed("SecKeyCopyPublicKey failed")
        }
        var repError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(
            publicKey,
            &repError
        ) else {
            let msg = (repError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown"
            throw SignerError.keyCreationFailed(
                "SecKeyCopyExternalRepresentation failed: \(msg)")
        }
        return (credentialID, publicKeyData as Data)
    }

    public func sign(message: Data, credentialID: Data) throws -> Data {
        // Pre-hash the message with SHA-256, then sign the DIGEST with the
        // *Digest* variant (NOT *Message*). Same convention as
        // `SecureEnclaveSigner` — the server computes sha256(message) once
        // and verifies; the Digest variant signs the pre-computed hash
        // without re-hashing.
        guard let key = try loadKey(credentialID: credentialID) else {
            throw SignerError.keyNotFound
        }
        let digest = Data(SHA256.hash(data: message))
        return try sign(digest: digest, with: key)
    }
}

// MARK: - SEPKeySigning

extension SoftwareSigner: SEPKeySigning {
    public func createKey(credentialID: Data) throws -> SecKey {
        // A plain software EC P-256 key: no kSecAttrTokenIDSecureEnclave
        // (the Secure Enclave is absent on simulators and Linux CI), no
        // .biometryAny access control (no Face ID prompt). This mirrors the
        // MockSEPKeySigner `.success` path — real keys, real signatures,
        // just not hardware-backed.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String:     kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &keyError
        ) else {
            let msg = (keyError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown"
            throw SignerError.keyCreationFailed(
                "SecKeyCreateRandomKey failed: \(msg)")
        }
        queue.sync { keys[credentialID] = privateKey }
        return privateKey
    }

    public func loadKey(credentialID: Data) throws -> SecKey? {
        // In-memory lookup: nil for "never created in this instance" —
        // mirrors the real signer's errSecItemNotFound → nil behavior.
        queue.sync { keys[credentialID] }
    }

    public func sign(digest: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureDigestX962SHA256,
            digest as CFData,
            &error
        ) else {
            let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown"
            throw SignerError.signingFailed(
                "SecKeyCreateSignature failed: \(msg)")
        }
        return signature as Data
    }
}

// MARK: - TeleportSEPSigning

extension SoftwareSigner: TeleportSEPSigning {}
