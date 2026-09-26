// SPDX-License-Identifier: MIT
//
//  MockSEPKeySigner.swift
//  VVTerm
//
//  A mock `SEPKeySigning` + `WebAuthnSigner` implementation for UI tests.
//
//  This is the key enabler for the Face ID outcome testability described in
//  the 2.2 UI design doc's CI strategy:
//
//    "The SecureEnclaveSigner is protocol-backed (SEPKeySigning), so the UI
//    tests inject a MockSEPKeySigner that returns .success(signature) or
//    .failure(LAError.userCancel / .biometryLockout / .biometryNotEnrolled).
//    This covers both the success path (signature flows through to /finish
//    → cert) and every failure path (cancel, lockout, not-enrolled,
//    unavailable) without a real SEP or real Face ID prompt."
//
//  The mock lets UI tests script Face ID outcomes deterministically — the
//  Face ID UX is fully testable in the simulator (where the real SEP / Face
//  ID prompt isn't available).
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (CI strategy —
//      "Face ID outcome is itself assertable")
//    - VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/Signer.swift
//      (WebAuthnSigner protocol)
//    - VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/SecureEnclaveSigner.swift
//      (SEPKeySigning protocol + SecureEnclaveSigner)
//    - VVTerm/Features/Teleport/Application/TeleportInfrastructureProtocols.swift
//      (TeleportSEPSigning = WebAuthnSigner & SEPKeySigning & AnyObject)
//

#if DEBUG
import Foundation
import Security
import CryptoKit

/// A mock SEP signer that scripts Face ID outcomes for UI tests.
///
/// Conforms to `TeleportSEPSigning` (= `WebAuthnSigner & SEPKeySigning &
/// AnyObject`) so it can be injected anywhere a real `SecureEnclaveSigner`
/// would be — the bootstrap, registration, and login coordinators, plus the
/// `TeleportKeyRing`.
///
/// The mock does NOT touch the Secure Enclave or prompt Face ID. Instead,
/// each method returns a scripted result based on the configured `outcome`:
///   - `.success`: createKey/loadKey/sign all succeed (with a real
///     in-memory P-256 key so signatures verify against the public key).
///   - `.cancelled`: sign() throws
///     `SignerError.biometricSigningFailed(_, errSecUserCanceled)` (the login
///     coordinator maps the typed OSStatus to `.faceIDCancelled`).
///   - `.lockout`: createKey/sign throw
///     `SignerError.biometricSigningFailed(_, errSecAuthFailed)` with a
///     lockout message (falls through the coordinator's string fallback — the
///     production lockout code is not established, see issue #221).
///   - `.notEnrolled`: createKey/sign throw
///     `SignerError.biometricSigningFailed(_, errSecInteractionNotAllowed)`
///     with a not-enrolled message (same string-fallback rationale).
final class MockSEPKeySigner: TeleportSEPSigning {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    /// The scripted Face ID outcome.
    enum Outcome {
        /// Face ID succeeds — the SEP key is created/loaded/signed without
        /// error. A real in-memory P-256 key backs the signature so it
        /// verifies against the public key (catches gross bugs in the
        /// WebAuthn builder path).
        case success
        /// The user cancelled the Face ID prompt (LAError.userCancel).
        /// `createKey` and `sign` throw — `loadKey` still returns nil
        /// (the key was never created).
        case cancelled
        /// Face ID is locked out (LAError.biometryLockout — too many failed
        /// attempts). `createKey` and `sign` throw a lockout-flavored error.
        case lockout
        /// Face ID isn't enrolled (LAError.biometryNotEnrolled). `createKey`
        /// and `sign` throw a not-enrolled-flavored error.
        case notEnrolled
    }

    let label = "mock-sep"
    let outcome: Outcome

    /// The credential ID → SecKey map (for loadKey round-trips within a
    /// single test run). Populated by `createKey(credentialID:)` on the
    /// `.success` outcome; `loadKey` returns the cached SecKey (or nil if
    /// the key was never created, mirroring the real signer's
    /// errSecItemNotFound → nil behavior).
    private var keys: [Data: SecKey] = [:]

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    // MARK: - WebAuthnSigner (builder-facing)

    func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        // createKey() (the builder-facing variant) generates a new credential
        // ID and delegates to createKey(credentialID:).
        let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let secKey = try createKey(credentialID: credentialID)
        guard let publicKey = SecKeyCopyPublicKey(secKey) else {
            throw SignerError.keyCreationFailed("SecKeyCopyPublicKey failed")
        }
        var error: Unmanaged<CFError>?
        guard let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw SignerError.keyCreationFailed("SecKeyCopyExternalRepresentation failed")
        }
        return (credentialID, pubData as Data)
    }

    func sign(message: Data, credentialID: Data) throws -> Data {
        // Pre-hash + delegate to sign(digest:with:).
        let digest = Data(SHA256.hash(data: message))
        // Look up the SecKey (in-memory cache).
        guard let key = keys[credentialID] else {
            throw SignerError.keyNotFound
        }
        return try sign(digest: digest, with: key)
    }

    // MARK: - SEPKeySigning (SecKey lifecycle)

    func createKey(credentialID: Data) throws -> SecKey {
        // The Face ID prompt fires here in the real signer. Script it.
        switch outcome {
        case .success:
            // Generate a real software P-256 SecKey so signatures verify
            // against the public key (catches gross bugs in the WebAuthn
            // builder path). We use a software key (not SEP) — the mock is
            // for testing coordinator state transitions, not the SEP itself.
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
            ]
            var error: Unmanaged<CFError>?
            guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
                throw SignerError.keyCreationFailed("mock SecKeyCreateRandomKey failed: \(msg)")
            }
            keys[credentialID] = secKey
            return secKey
        case .cancelled:
            // Face ID cancelled — surface the same typed OSStatus the real
            // signer throws, so the login coordinator's typed mapping is
            // exercised (not the string fallback).
            throw SignerError.biometricSigningFailed(
                "The user cancelled Face ID",
                errSecUserCanceled
            )
        case .lockout:
            // The production OSStatus for lockout is not established (issue
            // #221), so this is an arbitrary non-cancel code: the message
            // exercises the string fallback that stays in place for
            // unattributable codes (the fallback matches the "lockout"
            // substring).
            throw SignerError.biometricSigningFailed(
                "Face ID lockout",
                errSecAuthFailed
            )
        case .notEnrolled:
            throw SignerError.biometricSigningFailed(
                "Face ID is not enrolled",
                errSecInteractionNotAllowed
            )
        }
    }

    func loadKey(credentialID: Data) throws -> SecKey? {
        // loadKey doesn't prompt Face ID (it's a keychain query), so it
        // succeeds regardless of outcome — UNLESS the key was never created
        // (cancelled/lockout/notEnrolled on createKey), in which case it
        // returns nil (key absent).
        //
        // This mirrors the real signer's behavior: errSecItemNotFound → nil.
        return keys[credentialID]
    }

    func sign(digest: Data, with key: SecKey) throws -> Data {
        // The Face ID prompt fires here in the real signer. Script it.
        switch outcome {
        case .success:
            // Use the real SecKey to sign (so the signature is valid).
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                key,
                .ecdsaSignatureDigestX962SHA256,
                digest as CFData,
                &error
            ) else {
                let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
                throw SignerError.signingFailed("mock SecKeyCreateSignature failed: \(msg)")
            }
            return signature as Data
        case .cancelled:
            throw SignerError.biometricSigningFailed(
                "The user cancelled Face ID",
                errSecUserCanceled
            )
        case .lockout:
            throw SignerError.biometricSigningFailed(
                "Face ID lockout",
                errSecAuthFailed
            )
        case .notEnrolled:
            throw SignerError.biometricSigningFailed(
                "Face ID is not enrolled",
                errSecInteractionNotAllowed
            )
        }
    }
}
#endif
