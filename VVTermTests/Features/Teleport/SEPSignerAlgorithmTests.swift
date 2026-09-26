// SPDX-License-Identifier: MIT
//
//  SEPSignerAlgorithmTests.swift
//  VVTerm
//
//  Pins the Secure Enclave signer's signature algorithm without requiring
//  hardware: `sign(digest:with:)` must sign the already-hashed digest with
//  `.ecdsaSignatureDigestX962SHA256`, matching the macOS SEP path the server
//  verifies. The message variant would hash the digest a second time and the
//  server would reject the assertion.
//
//  A software P-256 `SecKey` exercises the same `SecKeyCreateSignature` code
//  path as a SEP-held key, so this runs on the simulator; the SEP key's
//  hardware custody stays device-smoke-only.
//

#if DEBUG
import CryptoKit
import Foundation
import Security
import XCTest
@testable import VVTerm

@MainActor
final class SEPSignerAlgorithmTests: XCTestCase {

    func testSignerSignsThePrehashedDigestWithTheSHA256DigestAlgorithm() throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw XCTSkip("SecKeyCreateRandomKey unavailable: \(String(describing: error))")
        }

        let digest = Data(SHA256.hash(data: Data("authData||clientDataHash".utf8)))
        let signer = SecureEnclaveSigner()
        let signature = try signer.sign(digest: digest, with: key)
        XCTAssertFalse(signature.isEmpty)

        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw XCTSkip("SecKeyCopyPublicKey unavailable")
        }
        XCTAssertTrue(
            SecKeyVerifySignature(
                publicKey,
                .ecdsaSignatureDigestX962SHA256,
                digest as CFData,
                signature as CFData,
                nil
            ),
            "the signature must verify against the pre-hashed digest"
        )

        // Signing the digest as a *message* would hash it again; the server
        // verifies the digest form, so this must not verify.
        XCTAssertFalse(
            SecKeyVerifySignature(
                publicKey,
                .ecdsaSignatureMessageX962SHA256,
                digest as CFData,
                signature as CFData,
                nil
            ),
            "the digest must not be signed as if it were a message"
        )
    }

    /// Pins the `SecKeyCreateRandomKey` attribute shape the device needs:
    /// `kSecAttrIsPermanent`, `kSecAttrApplicationLabel` and
    /// `kSecAttrAccessControl` describe the private key and must be nested
    /// under `kSecPrivateKeyAttrs`. The clean-room rewrite (`ba81877c`)
    /// flattened them, and every device registration then failed adding the
    /// key to the keychain with `errSecAuthFailed` (-25293) — a failure no
    /// simulator test could see, because the Secure Enclave is absent there
    /// (issue #261).
    func testKeyAttributesNestThePrivateKeyAttributes() throws {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny],
            &accessError
        ) else {
            throw XCTSkip(
                "SecAccessControlCreateWithFlags unavailable: \(String(describing: accessError))"
            )
        }

        let credentialID = Data((0..<32).map { UInt8($0) })
        let attributes = SecureEnclaveSigner.keyAttributes(
            credentialID: credentialID,
            accessControl: accessControl
        )

        XCTAssertEqual(
            attributes[kSecAttrTokenID as String] as? String,
            kSecAttrTokenIDSecureEnclave as String,
            "the credential must be Secure-Enclave-backed"
        )
        let privateKeyAttributes = try XCTUnwrap(
            attributes[kSecPrivateKeyAttrs as String] as? [String: Any],
            "the private-key attributes must be nested under kSecPrivateKeyAttrs"
        )
        XCTAssertEqual(
            privateKeyAttributes[kSecAttrIsPermanent as String] as? Bool,
            true,
            "the key must be persisted to the keychain"
        )
        XCTAssertEqual(
            privateKeyAttributes[kSecAttrApplicationLabel as String] as? Data,
            credentialID,
            "the credential id must be the raw application-label bytes"
        )
        let storedAccessControl = privateKeyAttributes[kSecAttrAccessControl as String] as AnyObject?
        XCTAssertNotNil(
            storedAccessControl,
            "the biometry access control must be applied to the private key"
        )
        XCTAssertTrue(
            storedAccessControl === accessControl,
            "the private key must carry the exact SecAccessControl instance"
        )
        for flattened in [
            kSecAttrIsPermanent,
            kSecAttrApplicationLabel,
            kSecAttrAccessControl,
        ] {
            XCTAssertNil(
                attributes[flattened as String],
                "\(flattened) must not be a top-level key-generation attribute"
            )
        }
    }
}

#endif
