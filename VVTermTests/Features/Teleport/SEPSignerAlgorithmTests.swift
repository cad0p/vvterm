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

    // MARK: - SEP-1: the load query scopes to the Secure Enclave

    /// Pins the whole `loadKeyQuery` dictionary (SEP-1): the token term the
    /// clean-room rewrite dropped, the retained key type, and the explicit
    /// absence of every key-*creation* attribute. A full-dictionary compare
    /// fails if the token term is dropped again (the regression) and catches
    /// accidental extra terms.
    func testLoadKeyQueryScopesToTheSecureEnclave() {
        let credentialID = Data((0..<32).map { UInt8($0) })
        let query = SecureEnclaveSigner.loadKeyQuery(credentialID: credentialID)

        let expected: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: credentialID,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        XCTAssertEqual(
            query as NSDictionary,
            expected as NSDictionary,
            "the load query must be the token-scoped, label+key-type, return-ref, match-one dictionary"
        )

        // Creation-only attributes must not leak into the lookup predicate:
        // `keyAttributes(credentialID:accessControl:)` owns those.
        for creationOnly in [
            kSecAttrIsPermanent,
            kSecPrivateKeyAttrs,
            kSecAttrAccessControl,
            kSecAttrKeySizeInBits,
        ] {
            XCTAssertNil(
                query[creationOnly as String],
                "\(creationOnly) is a key-creation attribute and must not appear in the load query"
            )
        }
    }

    /// SEP-2 source pin: `loadKey` always queries the keychain and never
    /// short-circuits on the in-process cache; the cache read is the
    /// `sign(message:credentialID:)` fast path.
    ///
    /// FORMATTING TRIPWIRE, NOT A PROOF: the slice is anchored on the
    /// function signature and its 4-space closing brace, so a rename or a
    /// restructure defeats it — re-verify the ordering when restructuring.
    func testLoadKeyQueriesTheKeychainAndDoesNotShortCircuitOnTheCache() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot().appendingPathComponent(
                "VVTerm/Features/Teleport/Infrastructure/SEPWebAuthn/SecureEnclaveSigner.swift"
            ),
            encoding: .utf8
        )

        let loadBody = try Self.functionBody(
            "public func loadKey(credentialID: Data)",
            in: source
        )
        XCTAssertTrue(
            loadBody.contains("SecItemCopyMatching"),
            "loadKey must query the keychain"
        )
        XCTAssertTrue(
            loadBody.contains("Self.loadKeyQuery(credentialID: credentialID)"),
            "loadKey must use the pinned query builder"
        )
        let cacheOccurrences = loadBody.components(separatedBy: "keys[credentialID]").count - 1
        XCTAssertEqual(
            cacheOccurrences,
            1,
            "loadKey must not short-circuit on the cache: only the post-query write may touch keys[...] (re-verify the ordering when restructuring)"
        )
        XCTAssertTrue(
            loadBody.contains("queue.sync { keys[credentialID] = key }"),
            "the post-query cache write must remain"
        )

        let signBody = try Self.functionBody(
            "public func sign(message: Data, credentialID: Data)",
            in: source
        )
        let cacheRead = try XCTUnwrap(
            signBody.range(of: "keys[credentialID]"),
            "sign(message:credentialID:) must read the cache first (re-verify the ordering when restructuring)"
        )
        let loadCall = try XCTUnwrap(
            signBody.range(of: "loadKey(credentialID: credentialID)"),
            "sign(message:credentialID:) must fall back to loadKey (re-verify the ordering when restructuring)"
        )
        XCTAssertLessThan(
            cacheRead.lowerBound,
            loadCall.lowerBound,
            "the cache read must precede the loadKey fallback"
        )
        XCTAssertTrue(
            signBody.contains("queue.sync(execute: { keys[credentialID] })"),
            "the cache read must be the sign fast path"
        )
    }

    /// SEP-1 behavioural candidate: a software P-256 key carrying the same
    /// `kSecAttrApplicationLabel` and `kSecAttrKeyType` must not satisfy the
    /// token-scoped load query. If the simulator ignores
    /// `kSecAttrTokenIDSecureEnclave` in queries this is red for the wrong
    /// reason; the source pin above is then the honest ceiling (recorded in
    /// the PR body).
    ///
    /// The credential id is fresh per run: a deterministic id could be left
    /// behind by a crashed run, and the resulting `errSecDuplicateItem` must
    /// be a visible failure, never a silent `XCTSkip` (a green non-test).
    /// `XCTSkip` is kept only for a genuinely unavailable keychain.
    func testLoadKeyDoesNotReturnASoftwareKeyWithTheSameCredentialLabel() throws {
        let credentialID = newCredentialID()
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationLabel: credentialID,
            ] as [CFString: Any],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            let failure = error?.takeRetainedValue()
            if let failure,
               (CFErrorGetDomain(failure) as String) == NSOSStatusErrorDomain,
               CFErrorGetCode(failure) == Int(errSecDuplicateItem)
            {
                return XCTFail(
                    "a leaked software key with this credential id already exists; the cleanup delete below did not run"
                )
            }
            throw XCTSkip(
                "could not create a persistent software key: \(String(describing: failure))"
            )
        }
        defer {
            let delete: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecAttrApplicationLabel: credentialID,
            ]
            let status = SecItemDelete(delete as CFDictionary)
            XCTAssertTrue(
                status == errSecSuccess || status == errSecItemNotFound,
                "the cleanup SecItemDelete must succeed; got OSStatus \(status)"
            )
        }

        let loaded = try SecureEnclaveSigner().loadKey(credentialID: credentialID)
        XCTAssertNil(
            loaded,
            "a software key with the same label must not match the SEP-scoped query"
        )
    }

    // MARK: - Source helpers

    /// The repository root, derived from this file's location
    /// (`VVTermTests/Features/Teleport/SEPSignerAlgorithmTests.swift`).
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SEPSignerAlgorithmTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
    }

    /// The text from `\(signature)` (the full `public func …` anchor) to the
    /// next 4-space closing brace — the body of a class-level method. The
    /// `public func` prefix is required because the protocol declares the
    /// unqualified signature first. A rename or re-indent breaks the anchor,
    /// which is why each assertion carries the "re-verify" message.
    private static func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: signature),
            "could not find \(signature)"
        )
        let end = try XCTUnwrap(
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex),
            "could not find the closing brace of \(signature)"
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

#endif
