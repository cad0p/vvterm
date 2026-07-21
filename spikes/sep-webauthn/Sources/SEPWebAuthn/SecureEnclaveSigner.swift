// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SecureEnclaveSigner.swift
//  SEPWebAuthn
//
//  Part B signer — SecKey* + kSecAttrTokenIDSecureEnclave. Creates a real
//  non-exportable EC-P256 key in the Secure Enclave. On the `macos-14`
//  GitHub Actions runner this exercises the identical API surface that iOS
//  will use in production; the attestation produced is byte-identical in
//  shape to what `tsh mfa add --type TOUCHID` produces on Mac.
//
//  Access control uses `.privateKeyUsage` ONLY — no `.biometryAny`. The
//  headless runner has no Touch ID sensor, so a biometry-gated key would
//  block forever on `SecKeyCreateSignature`. Part C (production smoke test)
//  adds `.biometryAny` on a real iPhone; that's out of scope for this spike
//  and orthogonal to the wire-format question Part B answers.

import Foundation
import Security
import CryptoKit

public final class SecureEnclaveSigner: WebAuthnSigner {
    public let label = "sep"

    /// Store the SecKey by credentialID so we can sign without re-querying
    /// the keychain. (We also persist via `kSecAttrIsPermanent`, so the key
    /// survives process restarts, but the spike is single-process.)
    private var keys: [Data: SecKey] = [:]
    private let queue = DispatchQueue(label: "sep-webauthn.sep-signer")

    public init() {}

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let credentialID = newCredentialID()

        // Mirrors register.m:34-61.
        // .privateKeyUsage only — see file header.
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "unknown"
            throw SignerError.keyCreationFailed(
                "SecAccessControlCreateWithFlags failed: \(msg)")
        }
        // access is a CFTypeRef that's ARC-managed in Swift — no CFRelease
        // needed (and CFRelease is explicitly unavailable from Swift).

        let attributes: [String: Any] = [
            kSecAttrKeyType as String:           kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String:     256,
            kSecAttrTokenID as String:           kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String:       true,
                kSecAttrAccessControl as String:     access,
                // label/tag disambiguate keys in the keychain; not strictly
                // needed for the spike (we hold the SecKey in-memory), but
                // included for parity with register.m.
                kSecAttrApplicationLabel as String:  credentialID,
            ] as [String: Any],
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

        // Extract public key in ANSI X9.63 form (0x04 || X || Y, 65 bytes).
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
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

        queue.sync { keys[credentialID] = privateKey }
        return (credentialID, publicKeyData as Data)
    }

    public func sign(message: Data, credentialID: Data) throws -> Data {
        let key: SecKey? = queue.sync { keys[credentialID] }
        guard let key else { throw SignerError.keyNotFound }

        // Mirror authenticate.m:55-59 — pre-hash the message with SHA-256,
        // then sign the DIGEST with kSecKeyAlgorithmECDSASignatureDigestX962SHA256
        // (the *Digest* variant, NOT *Message*). The *Digest* variant signs
        // the pre-computed hash directly without re-hashing.
        //
        // api.go:445 computes digest = sha256(authData || sha256(clientDataJSON))
        // and passes it to native.Authenticate → authenticate.m which calls
        // SecKeyCreateSignature with the Digest variant. The server
        // (go-webauthn EC2PublicKeyData.Verify) computes the same single
        // hash and verifies.
        //
        // Using the *Message* variant would double-hash and break verification
        // (this was the run #29838845521 bug — 'Unable to verify signature').
        let digest = Data(SHA256.hash(data: message))
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
