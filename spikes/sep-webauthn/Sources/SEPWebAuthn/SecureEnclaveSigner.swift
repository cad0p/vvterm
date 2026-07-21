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
//  Access control flags are selected by the `biometry` initializer argument:
//    - biometry=false (default): `.privateKeyUsage` only. Used by CI (Part B)
//      — the headless runner has no Touch ID sensor, so a biometry-gated key
//      would block forever on `SecKeyCreateSignature`.
//    - biometry=true: `.privateKeyUsage` + `.biometryAny`. Used by session
//      1.6b (Part C) — run on a real Mac with Touch ID or an iPhone with
//      Face ID. `SecKeyCreateSignature` then blocks until the user presents
//      biometry. The wire format is unchanged; only the access-control flags
//      differ. This is the production gating mode (session 2.2 Phase 2/3).

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

    /// When true, keys are created with `.biometryAny` access control in
    /// addition to `.privateKeyUsage`. `SecKeyCreateSignature` then blocks
    /// until the user presents Touch ID / Face ID. Used by session 1.6b
    /// (Part C) on a real device; NOT for the headless CI runner.
    private let biometry: Bool

    public init(biometry: Bool = false) {
        self.biometry = biometry
    }

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let credentialID = newCredentialID()

        // Mirrors register.m:34-61. Access-control flags:
        //   - default (CI):    .privateKeyUsage only
        //   - biometry (1.6b): .privateKeyUsage | .biometryAny
        // The wire format is identical in both cases; biometry only changes
        // the key's usage policy (gating SecKeyCreateSignature on a biometric
        // prompt). See session 1.6 prompt, test 1.6b.
        let flags: SecAccessControlCreateFlags
        if biometry {
            flags = [.privateKeyUsage, .biometryAny]
        } else {
            flags = .privateKeyUsage
        }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
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
                // kSecAttrIsPermanent:false — keep the key in-memory only,
                // NOT persisted to the keychain. A persistent SEP key
                // (kSecAttrIsPermanent:true, like Teleport's register.m uses)
                // requires the binary to be signed with a keychain-access-groups
                // entitlement; a `swift build` debug CLI is ad-hoc signed and
                // gets errSecMissingEntitlement (-34018) on key creation.
                // The spike is single-process and caches the SecKey in
                // `self.keys[credentialID]`, so transient is sufficient.
                // Production (session 2.2) will use kSecAttrIsPermanent:true
                // with a proper app signature.
                kSecAttrIsPermanent as String:       false,
                kSecAttrAccessControl as String:     access,
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
