// SPDX-License-Identifier: MIT
//
//  SEPSignerAlgorithmTests.swift
//  VVTermTests
//
//  Host-side coverage for the SEP signer's keychain queries. The package owns
//  the signature-algorithm and attribute-shape suites (`TeleportCoreTests`);
//  the one kept case pins that a *software* P-256 key with the same
//  `kSecAttrApplicationLabel` as a credential id must not satisfy the
//  SEP-scoped `loadKey` query — a simulator-visible stand-in for the
//  hardware-custody separation.
//
//  Split from the package-covered suite in the swift-teleport cutover: the
//  algorithm/attribute pins now live in the package, and this file keeps only
//  the host-observable keychain-query behaviour.
//

#if DEBUG
import Foundation
import Security
import XCTest
import TeleportCore
@testable import VVTerm

@MainActor
final class SEPSignerAlgorithmTests: XCTestCase {

    /// `kSecAttrApplicationLabel` and `kSecAttrKeyType` must not satisfy the
    /// token-scoped load query. If the simulator ignores
    /// `kSecAttrTokenIDSecureEnclave` in queries this is red for the wrong
    /// reason; the package's source pin is then the honest ceiling (recorded
    /// in the PR body).
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

    // MARK: - Helpers

    /// Generates a fresh 32-byte credential id.
    ///
    /// The package's `newCredentialID()` is `package`-visibility; this host
    /// copy matches that implementation (same RNG-failure precondition).
    private func newCredentialID() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with OSStatus \(status)")
        return Data(bytes)
    }
}

#endif
