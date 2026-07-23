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
    /// the keychain on every call. Keys are persisted via
    /// `kSecAttrIsPermanent:true` + `kSecAttrApplicationLabel: credentialID`,
    /// so they survive app relaunch; `loadKey(credentialID:)` reloads them
    /// into this cache after a relaunch.
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
                // kSecAttrIsPermanent:true — persist the SEP key to the
                // keychain so it survives app relaunch. Paired with
                // kSecAttrApplicationLabel (set to the credentialID) so the
                // key can be reloaded by credentialID in a later session
                // (see loadKey). The iotest app target is properly signed
                // (unlike the ad-hoc `swift build` CLI), so the keychain-
                // access-groups entitlement is present. This is the
                // production gating mode (session 2.2).
                kSecAttrIsPermanent as String:       true,
                kSecAttrApplicationLabel as String:  credentialID,
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
        var key: SecKey? = queue.sync { keys[credentialID] }
        // If the in-memory cache misses (e.g. app relaunched), try loading
        // the persistent SEP key from the keychain by its application label
        // (= credentialID). Throws keyNotFound if it's not there either.
        if key == nil {
            key = try loadKey(credentialID: credentialID)
        }
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

    /// Load a persistent SEP key from the keychain by its credentialID
    /// (= kSecAttrApplicationLabel, set at creation time). Used when the
    /// in-memory cache misses after an app relaunch, so Phase 3 can re-use
    /// a key registered in a previous session without re-running Phase 1+2.
    /// Caches the loaded SecKey in `self.keys` so subsequent signs skip the
    /// keychain lookup. Returns nil if no key with that credentialID exists.
    @discardableResult
    public func loadKey(credentialID: Data) throws -> SecKey? {
        // Check the cache first (cheap).
        if let cached = queue.sync(execute: { keys[credentialID] }) {
            return cached
        }
        let query: [String: Any] = [
            kSecClass as String:               kSecClassKey,
            kSecAttrKeyType as String:        kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrTokenID as String:        kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: credentialID,
            kSecReturnRef as String:          true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let secKey = ref else {
            // errSecItemNotFound → no key with that credentialID; return nil
            // (not a throw — the caller decides whether that's an error).
            return nil
        }
        queue.sync { keys[credentialID] = secKey as! SecKey }
        return secKey as! SecKey
    }
}
