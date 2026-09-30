// SPDX-License-Identifier: MIT
//
//  SecureEnclaveSigner.swift
//  VVTerm
//
//  The Secure Enclave-backed `WebAuthnSigner`.
//
//  Each credential is a permanent, non-exportable P-256 key created in the
//  Secure Enclave with a `privateKeyUsage` + `biometryAny` access control, so
//  every signature prompts Face ID / Touch ID. The key is addressed by its
//  credential id via `kSecAttrApplicationLabel`, which is also how
//  `TeleportKeyRing` checks readiness after an app relaunch; `loadKey` always
//  queries the keychain (the truth for "is this device registered") and the
//  in-memory cache is only the `sign(message:credentialID:)` fast path.
//
//  The Secure Enclave is absent on simulators and CI, so this path is covered
//  by the owner device smoke plus the protocol-level tests that inject
//  `SEPKeySigning` mocks. `SoftwareSigner` is the CI-friendly twin.
//

import Foundation
import Security
import CryptoKit

/// The lower-level Secure Enclave key lifecycle.
///
/// Split out from `WebAuthnSigner` so readiness checks and key recovery can
/// use a `SecKey` without going through the WebAuthn builder.
public protocol SEPKeySigning {
    /// Creates a permanent Secure Enclave key for `credentialID`.
    func createKey(credentialID: Data) throws -> SecKey

    /// Loads the key for `credentialID`, or nil when it does not exist.
    func loadKey(credentialID: Data) throws -> SecKey?

    /// Signs a pre-hashed digest (no re-hashing).
    func sign(digest: Data, with key: SecKey) throws -> Data
}

/// The Secure Enclave signer.
public final class SecureEnclaveSigner: WebAuthnSigner, SEPKeySigning {

    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}

    public let label = "sep"

    /// Credential id → SecKey, populated by `createKey`/`loadKey`.
    private var keys: [Data: SecKey] = [:]
    private let queue = DispatchQueue(label: "vvterm.sep-webauthn.sep-signer")

    public init() {}

    // MARK: - WebAuthnSigner

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let credentialID = newCredentialID()
        let key = try createKey(credentialID: credentialID)

        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw SignerError.keyCreationFailed("SecKeyCopyPublicKey failed")
        }
        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw SignerError.keyCreationFailed(
                "SecKeyCopyExternalRepresentation failed: \(Self.describe(error))"
            )
        }
        // SecKeyCopyExternalRepresentation returns the ANSI X9.63 point
        // (0x04 || X || Y) for EC keys.
        return (credentialID, representation as Data)
    }

    public func sign(message: Data, credentialID: Data) throws -> Data {
        // The in-process cache is the *signing* fast path (SEP-2): a key
        // created or loaded during this process is reused without another
        // `SecItemCopyMatching`. `loadKey` itself always queries the
        // keychain — the keychain, not the cache, is the truth for "is this
        // device registered" — so only this call site may consult the cache.
        let key: SecKey
        if let cached = queue.sync(execute: { keys[credentialID] }) {
            key = cached
        } else if let loaded = try loadKey(credentialID: credentialID) {
            key = loaded
            queue.sync { keys[credentialID] = loaded }
        } else {
            throw SignerError.keyNotFound
        }
        // Single-hash rule: the server hashes the message once and verifies
        // the DER signature against that digest.
        let digest = Data(SHA256.hash(data: message))
        return try sign(digest: digest, with: key)
    }

    // MARK: - SEPKeySigning

    public func createKey(credentialID: Data) throws -> SecKey {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny],
            &accessControlError
        ) else {
            throw SignerError.keyCreationFailed(
                "SecAccessControlCreateWithFlags failed: \(Self.describe(accessControlError))"
            )
        }

        let attributes = Self.keyAttributes(
            credentialID: credentialID,
            accessControl: accessControl
        )

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SignerError.keyCreationFailed(
                "SecKeyCreateRandomKey failed: \(Self.describe(error))"
            )
        }
        queue.sync { keys[credentialID] = key }
        return key
    }

    /// The `SecKeyCreateRandomKey` attributes for a permanent SEP credential.
    ///
    /// `kSecAttrIsPermanent`, `kSecAttrApplicationLabel` and
    /// `kSecAttrAccessControl` describe the *private* key and must be nested
    /// under `kSecPrivateKeyAttrs`. The clean-room rewrite (`ba81877c`)
    /// flattened them to the top level, so the framework never applied the
    /// private-key policy and every device registration failed adding the key
    /// to the keychain with `errSecAuthFailed` (-25293); the pre-rewrite
    /// handler and the device-proven spike both nest them. Kept as a pure
    /// builder so a simulator unit test can pin the shape without a Secure
    /// Enclave (issue #261).
    static func keyAttributes(
        credentialID: Data,
        accessControl: SecAccessControl
    ) -> [String: Any] {
        [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationLabel as String: credentialID,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]
    }

    /// The `SecItemCopyMatching` predicate for an existing SEP credential.
    ///
    /// `kSecAttrTokenIDSecureEnclave` scopes the query to SEP-resident keys
    /// so a software key with a colliding label cannot match (SEP-1: the
    /// clean-room rewrite dropped the token term; the pre-rewrite and
    /// device-proven form had it). `kSecAttrKeyType` is deliberately kept as
    /// well, making this a strict subset of both prior predicates: the key is
    /// always created with the EC prime-random type
    /// (`keyAttributes(credentialID:accessControl:)`). `kSecReturnRef`
    /// returns the `SecKey` directly (the external representation would fail
    /// for a non-exportable SEP key) and `kSecMatchLimitOne` returns a single
    /// result. Kept as a pure builder so a simulator unit test can pin the
    /// whole dictionary without a Secure Enclave.
    static func loadKeyQuery(credentialID: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: credentialID,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    public func loadKey(credentialID: Data) throws -> SecKey? {
        // Always query the keychain (SEP-2): a top-of-function cache
        // short-circuit could serve a stale in-process `SecKey` after the
        // keychain item is gone, and readiness must see the item's real
        // state. The cache stays the `sign(message:credentialID:)` fast
        // path and is not evicted on `errSecItemNotFound` (exactly pre);
        // only `sign` consults it.
        let query = Self.loadKeyQuery(credentialID: credentialID)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // An absent key is not an error: the readiness check relies on
            // nil to mean "this device has not registered yet".
            return nil
        }
        // D4 (accepted + recorded): pre returned nil for `errSecSuccess` with
        // a nil ref; this throws `keyCreationFailed` instead. A nil ref on
        // success is a keychain fault, not "no key", so the throw is strictly
        // better.
        guard status == errSecSuccess, let key = result as! SecKey? else {
            throw SignerError.keyCreationFailed("SecItemCopyMatching failed with OSStatus \(status)")
        }
        queue.sync { keys[credentialID] = key }
        return key
    }

    public func sign(digest: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureDigestX962SHA256,
            digest as CFData,
            &error
        ) else {
            // Consume the CFError exactly once (both the message and the
            // domain/code read from it).
            let cfError = error?.takeRetainedValue()
            let message = "SecKeyCreateSignature failed: \(Self.describe(cfError))"
            // The Face ID prompt's outcomes surface as a Security-framework
            // status in `NSOSStatusErrorDomain` (`errSecUserCanceled`,
            // `errSecAuthFailed`, ...), never as an `LAError`: this path has no
            // `LAContext`. Carry the status so the coordinator can classify
            // without the OS-localized text; the message keeps the frozen
            // `"signing failed: ..."` description shape.
            if let cfError, (CFErrorGetDomain(cfError) as String) == NSOSStatusErrorDomain {
                throw SignerError.biometricSigningFailed(
                    message,
                    OSStatus(truncatingIfNeeded: CFErrorGetCode(cfError))
                )
            }
            throw SignerError.signingFailed(message)
        }
        return signature as Data
    }

    // MARK: - Helpers

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown" }
        return describe(error.takeRetainedValue())
    }

    private static func describe(_ error: CFError?) -> String {
        guard let error else { return "unknown" }
        return (error as Error).localizedDescription
    }
}
