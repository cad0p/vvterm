// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SecureEnclaveSigner.swift
//  VVTerm
//
//  Part B signer — SecKey* + kSecAttrTokenIDSecureEnclave. Creates a real
//  non-exportable EC-P256 key in the Secure Enclave. On the `macos-14`
//  GitHub Actions runner this exercises the identical API surface that iOS
//  will use in production; the attestation produced is byte-identical in
//  shape to what `tsh mfa add --type TOUCHID` produces on Mac.
//
//  Adapted from spikes/sep-webauthn/Sources/SEPWebAuthn/SecureEnclaveSigner.swift
//  for production (session 2.2). Changes vs the spike:
//
//    1. Persistent key: `kSecAttrIsPermanent: true` + `kSecAttrApplicationLabel:
//       credentialID` when creating the key via `SecKeyCreateRandomKey`.
//       The spike used a non-persistent (in-memory) key because the ad-hoc-
//       signed `swift build` CLI got errSecMissingEntitlement (-34018) on
//       keychain persistence. The production app signature carries the
//       keychain-access-groups entitlement, so persistence works (proven in
//       session 1.12, PR #29). The key now survives process relaunch.
//
//    2. `loadKey(credentialID:)`: loads an existing SEP key via
//       `SecItemCopyMatching` (query by `kSecAttrApplicationLabel`). Used at
//       Phase 3 login to recover the key created at Phase 2 registration.
//       Proven in 1.12.
//
//    3. Protocol-backed for testability: conforms to `SEPKeySigning` so UI
//       tests can inject a `MockSEPKeySigner` (see the 2.2 UI design doc's
//       CI strategy). Also still conforms to `WebAuthnSigner` (the spike's
//       builder abstraction) so the same `WebAuthn.register`/`login` builders
//       work unchanged.
//
//    4. Access control: `.biometryAny` (proven in 1.6b). The signature
//       algorithm is `.ecdsaSignatureDigestX962SHA256` (the *Digest* variant,
//       confirmed correct by 1.5 + the full 1.12 chain — kept as-is).
//
//    5. LAContext: the spike did not manage an LAContext (each
//       `SecKeyCreateSignature` prompted fresh). Production keeps the same
//       behaviour — no `LAContext` reuse — because Phase 3 login is a single
//       signature per session and prompt reuse adds complexity without UX
//       benefit. If cert-refresh batching ever needs multiple signatures in
//       one prompt, an `LAContext` can be threaded through then.

import Foundation
import Security
import CryptoKit

/// A protocol-backed abstraction over the Secure Enclave key lifecycle, so
/// UI tests can inject a `MockSEPKeySigner` that returns scripted outcomes
/// (success / `.userCancel` / `.biometryLockout` / `.biometryNotEnrolled`)
/// without a real SEP or real Face ID prompt.
///
/// The `WebAuthnSigner` protocol (in `Signer.swift`) is a higher-level
/// abstraction for the WebAuthn builder (it takes a `message` and hashes
/// internally). `SEPKeySigning` is the lower-level SecKey-centric lifecycle
/// (create / load / sign-a-prehashed-digest) that the Teleport coordinators
/// depend on directly for Phase 2 registration and Phase 3 login.
public protocol SEPKeySigning {
    /// Create a new SEP-resident P-256 key, persisted to the keychain under
    /// `credentialID` (via `kSecAttrApplicationLabel`). The key is
    /// non-exportable and gated on `.biometryAny`.
    ///
    /// - Parameter credentialID: the opaque credential identifier bytes.
    ///   Used as the `kSecAttrApplicationLabel` for later `loadKey` lookup,
    ///   and emitted as the WebAuthn credential `id`/`rawId`.
    /// - Returns: the newly created `SecKey`.
    /// - Throws: `SignerError.keyCreationFailed` if the key cannot be created.
    func createKey(credentialID: Data) throws -> SecKey

    /// Load an existing SEP key previously created via `createKey`.
    ///
    /// - Parameter credentialID: the `kSecAttrApplicationLabel` the key was
    ///   stored under.
    /// - Returns: the `SecKey`, or `nil` if no key exists for this credential
    ///   ID (e.g. fresh device via iCloud, or key was deleted).
    /// - Throws: `SignerError` if the keychain query itself fails (not if the
    ///   key is simply absent — that's `nil`).
    func loadKey(credentialID: Data) throws -> SecKey?

    /// Sign a pre-hashed digest with a SEP key.
    ///
    /// Uses `.ecdsaSignatureDigestX962SHA256` — the *Digest* variant, which
    /// signs the pre-computed SHA-256 hash directly WITHOUT re-hashing. The
    /// caller MUST compute `digest = SHA256(message)` before calling; passing
    /// a raw message here would double-hash and break verification (this was
    /// run #29838845521's bug).
    ///
    /// `SecKeyCreateSignature` blocks until the user presents Touch ID / Face
    /// ID (because the key was created with `.biometryAny` access control).
    ///
    /// - Parameters:
    ///   - digest: the pre-computed SHA-256 digest to sign.
    ///   - key: the `SecKey` to sign with (from `createKey` or `loadKey`).
    /// - Returns: the raw ECDSA signature in ASN.1 DER
    ///   `SEQUENCE { r INTEGER, s INTEGER }` form.
    /// - Throws: `SignerError.signingFailed` (wrapping the underlying
    ///   `LAError` / `OSStatus`) if signing fails — including `.userCancel`,
    ///   `.biometryLockout`, `.biometryNotEnrolled`.
    func sign(digest: Data, with key: SecKey) throws -> Data
}

public final class SecureEnclaveSigner: WebAuthnSigner {
    public let label = "sep"

    /// Store the SecKey by credentialID so we can sign without re-querying
    /// the keychain within a single process. The key is ALSO persisted via
    /// `kSecAttrIsPermanent: true` + `kSecAttrApplicationLabel`, so it
    /// survives process restarts — `loadKey(credentialID:)` recovers it.
    private var keys: [Data: SecKey] = [:]
    private let queue = DispatchQueue(label: "vvterm.sep-webauthn.sep-signer")

    public init() {}

    // MARK: - WebAuthnSigner (builder-facing)

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let credentialID = newCredentialID()
        let privateKey = try createKey(credentialID: credentialID)

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

        return (credentialID, publicKeyData as Data)
    }

    public func sign(message: Data, credentialID: Data) throws -> Data {
        // Prefer the in-process cache; fall back to the persisted keychain key
        // (covers the Phase 3 relaunch case where the key was created in a
        // prior app run).
        let key: SecKey
        if let cached = queue.sync(execute: { keys[credentialID] }) {
            key = cached
        } else if let loaded = try loadKey(credentialID: credentialID) {
            key = loaded
            queue.sync { keys[credentialID] = loaded }
        } else {
            throw SignerError.keyNotFound
        }

        // Pre-hash the message with SHA-256, then sign the DIGEST with the
        // *Digest* variant (NOT *Message*). See sign(digest:with:) doc.
        let digest = Data(SHA256.hash(data: message))
        return try sign(digest: digest, with: key)
    }
}

// MARK: - SEPKeySigning

extension SecureEnclaveSigner: SEPKeySigning {
    public func createKey(credentialID: Data) throws -> SecKey {
        // Access-control flags: `.privateKeyUsage` + `.biometryAny`.
        // `.biometryAny` gates `SecKeyCreateSignature` on a biometric prompt
        // (Face ID / Touch ID). Proven in 1.6b on both Mac (Touch ID) and
        // iPhone (Face ID). The wire format is identical to the non-biometry
        // case; only the usage policy differs.
        let flags: SecAccessControlCreateFlags = [.privateKeyUsage, .biometryAny]
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
        // `access` is a CFTypeRef that's ARC-managed in Swift — no CFRelease
        // needed (and CFRelease is explicitly unavailable from Swift).

        // `kSecAttrIsPermanent: true` + `kSecAttrApplicationLabel: credentialID`
        // persists the SEP key to the keychain so it survives app relaunch.
        // The spike used `kSecAttrIsPermanent: false` because the ad-hoc-signed
        // `swift build` CLI hit errSecMissingEntitlement (-34018). The
        // production app carries the keychain-access-groups entitlement, so
        // persistence works (proven 1.12, PR #29).
        //
        // `kSecAttrApplicationLabel` is the lookup key for `loadKey` — it
        // must be the raw `credentialID` bytes (Data), not a stringified form.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String:           kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String:     256,
            kSecAttrTokenID as String:           kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
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

        queue.sync { keys[credentialID] = privateKey }
        return privateKey
    }

    public func loadKey(credentialID: Data) throws -> SecKey? {
        // Query by `kSecAttrApplicationLabel` (the credentialID the key was
        // stored under at creation). `kSecAttrTokenIDSecureEnclave` scopes the
        // query to SEP-resident keys so we don't accidentally pull a software
        // key with a colliding label.
        //
        // `kSecReturnRef: true` returns the `SecKey` directly (not its data
        // representation, which would fail for a non-exportable SEP key).
        // `kSecMatchLimit: kSecMatchLimitOne` returns a single result.
        //
        // `errSecItemNotFound` is a normal "no key exists" outcome — return
        // `nil` rather than throwing, so callers can branch on optional.
        let query: [String: Any] = [
            kSecClass as String:                kSecClassKey,
            kSecAttrTokenID as String:          kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: credentialID,
            kSecReturnRef as String:            true,
            kSecMatchLimit as String:           kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let secKey = result else {
                // Should not happen (errSecSuccess with nil ref), but defend.
                return nil
            }
            let key = (secKey as! SecKey)
            queue.sync { keys[credentialID] = key }
            return key
        case errSecItemNotFound:
            // No key exists for this credentialID — fresh device, or the key
            // was deleted. Not an error; the caller decides what to do.
            return nil
        default:
            // A genuine keychain failure (e.g. errSecMissingEntitlement,
            // errSecAuthFailed). Surface it so the caller can distinguish
            // "key absent" (nil) from "keychain broken" (throw).
            throw SignerError.keyCreationFailed(
                "SecItemCopyMatching failed: OSStatus \(status)")
        }
    }

    public func sign(digest: Data, with key: SecKey) throws -> Data {
        // Mirror authenticate.m:55-59 — sign the pre-computed DIGEST with
        // `.ecdsaSignatureDigestX962SHA256` (the *Digest* variant, NOT
        // *Message*). The *Digest* variant signs the pre-computed hash
        // directly without re-hashing.
        //
        // api.go:445 computes digest = sha256(authData || sha256(clientDataJSON))
        // and passes it to native.Authenticate → authenticate.m which calls
        // SecKeyCreateSignature with the Digest variant. The server
        // (go-webauthn EC2PublicKeyData.Verify) computes the same single
        // hash and verifies.
        //
        // Using the *Message* variant would double-hash and break verification
        // (this was the run #29838845521 bug — 'Unable to verify signature').
        //
        // `SecKeyCreateSignature` blocks until the user presents biometry
        // (because the key was created with `.biometryAny`). A user cancel
        // surfaces as an `LAError.userCancel` wrapped in the CFError.
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
