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

    public func sign(digest: Data, credentialID: Data) throws -> Data {
        let key: SecKey? = queue.sync { keys[credentialID] }
        guard let key else { throw SignerError.keyNotFound }

        // .ecdsaSignatureMessageX962SHA256 takes the *message* (pre-hash) and
        // internally hashes it with SHA-256. api.go pre-hashes
        // (authData || clientDataHash) with SHA-256 and passes the *digest*
        // to native.Authenticate, which calls SecKeyCreateSignature with
        // .ecdsaSignatureMessageX962SHA256 — i.e. the digest gets hashed
        // AGAIN by the SEP. **This double-hash is a load-bearing detail**
        // and is reproduced exactly here to match the Go path byte-for-byte.
        //
        // (If the spike is later rewritten to pass the *message* instead of
        // the digest, the Go path would also have to change — and vice versa.
        // The fixture byte-comparison in FixtureTests.swift catches any
        // divergence.)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
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
