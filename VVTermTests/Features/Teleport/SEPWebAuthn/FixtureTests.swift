// SPDX-License-Identifier: MIT
//
//  FixtureTests.swift
//  VVTermTests
//
//  Byte-compares Swift output against the committed Go-generated fixtures to
//  catch transcription errors in the CBOR / attestation / clientDataJSON
//  building.
//
//  Ported from spikes/sep-webauthn/Tests/SEPWebAuthnTests/FixtureTests.swift.
//  Two adaptations for the VVTermTests target:
//    1. `@testable import VVTerm` (was `@testable import SEPWebAuthn`) — the
//       SEPWebAuthn sources now live in the VVTerm app module.
//    2. Fixture path resolution walks up to the repo root then into
//       `spikes/sep-webauthn/fixtures/expected/`.
//
//  The 8 fixtures under `spikes/sep-webauthn/fixtures/expected/` are COMMITTED
//  test data and FULLY REPRODUCIBLE: the Go generator
//  (`spikes/sep-webauthn/fixtures/generate/main.go`) derives a fixed P-256 key
//  from a domain-separated seed and signs with RFC 6979 deterministic ECDSA,
//  so a fresh generator run byte-matches the committed set. If the generator
//  changes, regenerate and commit all 8 files together
//  (`spikes/sep-webauthn/fixtures/regenerate.sh`).
//
//  An absent fixture is a HARD FAILURE (`XCTFail` + throw), never a skip:
//  this byte comparison is the acceptance oracle for the clean-room rewrite
//  of the SEPWebAuthn sources, so it must not silently disappear.
//
//  What's compared:
//    - collectedClientData JSON bytes (3-field form, base64url challenge)
//    - authenticatorData bytes (rpIdHash || flags || signCount || [attData])
//    - COSE EC2 public key CBOR bytes
//    - full attestation object CBOR bytes (with the committed Go signature)
//    - the committed Go signature verifies against the committed Go public
//      key over SHA256(attData.message)
//
//  What's NOT compared:
//    - A Swift-generated signature (the private key is not committed and the
//      Swift signer is software/SEP, not the generator's key). The signer
//      path is covered by the software-signer round-trip below.

import XCTest
@testable import VVTerm
import CryptoKit
import Security

final class FixtureTests: XCTestCase {

    // Test vector — MUST match fixtures/generate/main.go exactly.
    // (Changing these requires regenerating the fixtures.)
    static let origin       = "https://goteleport.com"
    static let rpID         = "goteleport.com"
    static let challenge    = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    static let credentialID = "11111111-2222-3333-4444-555555555555"  // UUID string, like api.go uses
    // The Go fixture's P-256 public key is committed at
    // fixtures/expected/pub_key_raw.bin (65 bytes, 0x04 || X || Y) and is
    // loaded at test time; the matching private key is not committed.

    private enum FixtureTestFailure: Error {
        case missingFixture(String)
    }

    // MARK: - helpers

    private func fixtureBaseURL() -> URL {
        // This test file lives at VVTermTests/Features/Teleport/SEPWebAuthn/.
        // Fixtures live at spikes/sep-webauthn/fixtures/expected/ (relative to
        // the repo root). Walk up from this file to the repo root, then down
        // into the spike's fixtures/expected/ directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // remove FixtureTests.swift
            .deletingLastPathComponent()  // remove SEPWebAuthn/
            .deletingLastPathComponent()  // remove Teleport/
            .deletingLastPathComponent()  // remove Features/
            .deletingLastPathComponent()  // remove VVTermTests/
        return repoRoot
            .appendingPathComponent("spikes/sep-webauthn/fixtures/expected")
    }

    /// Loads a committed fixture. A missing file is a hard failure (never a
    /// skip) because the committed fixtures are the rewrite's byte-exact
    /// oracle.
    private func requireFixture(_ name: String) throws -> Data {
        let url = fixtureBaseURL().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail(
                "Missing fixture \(name) at \(url.path). The fixture oracle is "
                + "committed under spikes/sep-webauthn/fixtures/expected/ "
                + "(regenerate with spikes/sep-webauthn/fixtures/regenerate.sh). "
                + "An absent fixture is a hard failure, never a skip."
            )
            throw FixtureTestFailure.missingFixture(name)
        }
        return data
    }

    // MARK: - tests

    func testCollectedClientDataJSON_matchesGoFixture() throws {
        // Go fixture: fixtures/expected/client_data_create.json
        // (and client_data_get.json for the assertion ceremony)
        let ccd = CollectedClientData(
            type: CeremonyType.create.rawValue,
            challenge: Self.challenge.base64URLEncodedString(),
            origin: Self.origin
        )
        let swiftJSON = ccd.toJSONBytes()

        let expected = try requireFixture("client_data_create.json")
        XCTAssertEqual(
            swiftJSON, expected,
            "clientDataJSON mismatch (create ceremony).\n" +
            "Swift: \(String(data: swiftJSON, encoding: .utf8) ?? "<bin>")\n" +
            "Go:    \(String(data: expected, encoding: .utf8) ?? "<bin>")"
        )

        // Also check the get ceremony.
        let ccdGet = CollectedClientData(
            type: CeremonyType.get.rawValue,
            challenge: Self.challenge.base64URLEncodedString(),
            origin: Self.origin
        )
        let swiftJSONGet = ccdGet.toJSONBytes()
        let expectedGet = try requireFixture("client_data_get.json")
        XCTAssertEqual(
            swiftJSONGet, expectedGet,
            "clientDataJSON mismatch (get ceremony).\n" +
            "Swift: \(String(data: swiftJSONGet, encoding: .utf8) ?? "<bin>")\n" +
            "Go:    \(String(data: expectedGet, encoding: .utf8) ?? "<bin>")"
        )
    }

    func testAuthenticatorData_matchesGoFixture() throws {
        // Load the committed public key from the fixture.
        let pubKeyRaw = try requireFixture("pub_key_raw.bin")
        XCTAssertEqual(pubKeyRaw.count, 65, "pub key should be 65 bytes")
        XCTAssertEqual(pubKeyRaw[0], 0x04, "pub key should start with 0x04")

        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: pubKeyRaw)
        let cred = CredentialData(
            id: Data(Self.credentialID.utf8),
            pubKeyCBOR: pubKeyCBOR
        )
        let attData = try makeAttestationData(
            ceremony: .create,
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            cred: cred
        )

        // Compare the COSE public key CBOR.
        let expectedPubKeyCBOR = try requireFixture("cose_pubkey.cbor")
        XCTAssertEqual(
            pubKeyCBOR, expectedPubKeyCBOR,
            "COSE EC2 public key CBOR mismatch.\n" +
            "Swift: \(pubKeyCBOR.map { String(format: "%02x", $0) }.joined())\n" +
            "Go:    \(expectedPubKeyCBOR.map { String(format: "%02x", $0) }.joined())"
        )

        // Compare the authenticatorData bytes.
        let expectedAuthData = try requireFixture("auth_data_create.bin")
        XCTAssertEqual(
            attData.rawAuthData, expectedAuthData,
            "authenticatorData mismatch (create).\n" +
            "Swift: \(attData.rawAuthData.map { String(format: "%02x", $0) }.joined())\n" +
            "Go:    \(expectedAuthData.map { String(format: "%02x", $0) }.joined())"
        )

        // get ceremony authData (no attested credential data).
        let attDataGet = try makeAttestationData(
            ceremony: .get,
            origin: Self.origin,
            rpID: Self.rpID,
            challenge: Self.challenge,
            cred: nil
        )
        let expectedAuthDataGet = try requireFixture("auth_data_get.bin")
        XCTAssertEqual(
            attDataGet.rawAuthData, expectedAuthDataGet,
            "authenticatorData mismatch (get).\n" +
            "Swift: \(attDataGet.rawAuthData.map { String(format: "%02x", $0) }.joined())\n" +
            "Go:    \(expectedAuthDataGet.map { String(format: "%02x", $0) }.joined())"
        )
    }

    func testAttestationObject_matchesGoFixture() throws {
        // Compare the full attestation object CBOR against the Go-generated
        // fixture. The committed fixture set is the deterministic generator's
        // output (fixed key + RFC 6979 signature), and includes both the
        // signature and the full attObj under fixtures/expected/.
        //
        // We reproduce the same authData (via the fixed test inputs) and
        // pass the committed Go signature into buildAttestationObjectCBOR,
        // then byte-compare the result against the Go attObj fixture.
        let pubKeyRaw = try requireFixture("pub_key_raw.bin")
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: pubKeyRaw)
        let cred = CredentialData(
            id: Data(Self.credentialID.utf8),
            pubKeyCBOR: pubKeyCBOR
        )
        let attData = try makeAttestationData(
            ceremony: .create, origin: Self.origin, rpID: Self.rpID,
            challenge: Self.challenge, cred: cred
        )

        // Load the committed Go-generated signature (from the same run as the
        // committed public key).
        let goSignature = try requireFixture("signature_create.der")

        // Build the Swift attObj with the Go fixture's signature.
        let swiftAttObj = WebAuthn.buildAttestationObjectCBOR(
            authData: attData.rawAuthData,
            signature: goSignature
        )

        // Compare against the Go-generated attObj fixture.
        let expectedAttObj = try requireFixture("attestation_object_create.cbor")
        XCTAssertEqual(
            swiftAttObj, expectedAttObj,
            "attestation object CBOR mismatch.\n" +
            "Swift: \(swiftAttObj.map { String(format: "%02x", $0) }.joined())\n" +
            "Go:    \(expectedAttObj.map { String(format: "%02x", $0) }.joined())"
        )
    }

    /// Verifies the committed Go signature against the committed Go public key
    /// over `SHA256(attData.message)`. This is the load-bearing addition:
    /// without it, the attestation-object comparison above would still pass if
    /// the Swift `message` (authData || clientDataHash) were wrong, because
    /// the test injects the Go signature without ever validating what it signs.
    func testCommittedGoSignature_verifiesAgainstCommittedPublicKey() throws {
        let pubKeyRaw = try requireFixture("pub_key_raw.bin")
        let goSignature = try requireFixture("signature_create.der")

        // Rebuild the exact create-ceremony message the Go generator signed.
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: pubKeyRaw)
        let cred = CredentialData(
            id: Data(Self.credentialID.utf8),
            pubKeyCBOR: pubKeyCBOR
        )
        let attData = try makeAttestationData(
            ceremony: .create, origin: Self.origin, rpID: Self.rpID,
            challenge: Self.challenge, cred: cred
        )

        // The Go generator signs sha256(message) directly (ecdsa.SignASN1
        // takes a pre-hashed digest). CryptoKit's isValidSignature(_:for:)
        // with a SHA256.Digest does the same single-hash verification.
        let p256Key = try P256.Signing.PublicKey(x963Representation: pubKeyRaw)
        let derSig = try P256.Signing.ECDSASignature(derRepresentation: goSignature)
        let messageDigest = SHA256.hash(data: attData.message)
        XCTAssertTrue(
            p256Key.isValidSignature(derSig, for: messageDigest),
            "The committed Go signature does not verify against the committed "
            + "Go public key over SHA256(attData.message) — the fixture set is "
            + "mismatched (regenerate and commit all 8 files together), or the "
            + "Swift message/authData derivation drifted."
        )

        // Pin the two facts the verification depends on, so a drift is
        // diagnosable from the failure without re-deriving by hand.
        XCTAssertEqual(
            attData.message,
            attData.rawAuthData + Data(SHA256.hash(data: attData.ccdJSON)),
            "message must be authData || SHA256(clientDataJSON)"
        )
        XCTAssertEqual(
            attData.digest,
            Data(SHA256.hash(data: attData.message)),
            "digest must be SHA256(message)"
        )
    }

    // MARK: - software signer round-trip (no Go fixture needed)

    func testSoftwareSigner_signatureVerifiesAgainstPublicKey() throws {
        // Generate a software key, sign a digest, verify the signature
        // against the extracted public key. This catches gross bugs in the
        // signer / digest-passing path that would cause server rejection.
        let signer = SoftwareSigner()
        let (credID, pubKeyRaw) = try signer.createKey()
        XCTAssertEqual(pubKeyRaw.count, 65)
        XCTAssertEqual(pubKeyRaw[0], 0x04)

        // Build a create-ceremony attestation, sign the message.
        let pubKeyCBOR = try coseEC2PublicKeyCBOR(publicKeyRaw: pubKeyRaw)
        let attData = try makeAttestationData(
            ceremony: .create, origin: Self.origin, rpID: Self.rpID,
            challenge: Self.challenge,
            cred: CredentialData(id: credID, pubKeyCBOR: pubKeyCBOR)
        )
        let sig = try signer.sign(message: attData.message, credentialID: credID)
        XCTAssertGreaterThanOrEqual(sig.count, 8, "DER ECDSA sig should be ≥8 bytes")
        XCTAssertLessThanOrEqual(sig.count, 72, "DER ECDSA sig should be ≤72 bytes")

        // Verify with CryptoKit: the server computes sha256(message) and
        // verifies. CryptoKit's isValidSignature(sig, for: SHA256.hash(data:))
        // does the same single hash.
        let p256Key = try P256.Signing.PublicKey(x963Representation: pubKeyRaw)
        let derSig = try P256.Signing.ECDSASignature(derRepresentation: sig)
        let messageDigest = SHA256.hash(data: attData.message)
        XCTAssertTrue(
            p256Key.isValidSignature(derSig, for: messageDigest),
            "SoftwareSigner signature failed to verify against its public key"
        )
    }

    func testCredentialID_isUUIDString_forProductionParity() throws {
        // In api_darwin.go:204 the credential ID is `uuid.NewString()`.
        // The spike uses a base64url-encoded random 32-byte value — this
        // is fine for the wire format (any opaque string works), but let's
        // confirm the CLI uses something string-shaped so the `id`/`rawId`
        // base64url encoding round-trips correctly.
        let signer = SoftwareSigner()
        let (credID, _) = try signer.createKey()
        let credIDString = credID.base64URLEncodedString()
        XCTAssertFalse(credIDString.isEmpty, "credential ID string must not be empty")
        // Round-trip: decode the base64url string back to bytes, should
        // equal the original credential ID bytes.
        let decoded = Data(base64URLEncoded: credIDString)
        XCTAssertEqual(decoded, credID, "credential ID base64url decode failed")
    }

    // MARK: - TeleportSEPSigning conformance (issue #83 M4)

    func testSoftwareSigner_sepKeySigningLifecycleRoundTrip() throws {
        // The CI integration test injects a `SoftwareSigner` as `any
        // TeleportSEPSigning` into the registration + login coordinators
        // (the app's Phase-2/Phase-3 ceremonies). This test locks in the
        // `SEPKeySigning` lifecycle the coordinators rely on: createKey
        // (SecKey) -> loadKey returns the same key -> sign(digest:with:)
        // produces a signature that verifies against the public key.
        let signer = SoftwareSigner()
        let credentialID = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // createKey(credentialID:) -> loadKey(credentialID:) round-trip.
        let secKey = try signer.createKey(credentialID: credentialID)
        let loaded = try signer.loadKey(credentialID: credentialID)
        XCTAssertNotNil(loaded, "loadKey must return the key created by createKey")
        XCTAssertEqual(loaded, secKey)

        // A never-created credential ID returns nil (mirrors the real
        // signer's errSecItemNotFound -> nil), not an error.
        let missing = try signer.loadKey(credentialID: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        XCTAssertNil(missing)

        // sign(digest:with:) — pre-hashed digest, DER ECDSA signature. Verify
        // with the symmetric SecKeyVerifySignature + the SAME Digest
        // algorithm (CryptoKit's isValidSignature(_:for:) re-hashes its
        // argument, which would double-hash the pre-hashed digest). The
        // server does the same single-hash verification.
        let digest = Data(SHA256.hash(data: Data("teleport-m4-ceremony-message".utf8)))
        let signature = try signer.sign(digest: digest, with: secKey)
        guard let publicKey = SecKeyCopyPublicKey(secKey) else {
            return XCTFail("SecKeyCopyPublicKey failed")
        }
        var verifyError: Unmanaged<CFError>?
        XCTAssertTrue(
            SecKeyVerifySignature(
                publicKey,
                .ecdsaSignatureDigestX962SHA256,
                digest as CFData,
                signature as CFData,
                &verifyError
            ),
            "SEPKeySigning signature failed to verify against the public key"
        )
    }

    func testSoftwareSigner_satisfiesTeleportSEPSigning() {
        // Compile-time + type-level lock: the coordinators take `any
        // TeleportSEPSigning`, so the software signer must conform.
        let signer: any TeleportSEPSigning = SoftwareSigner()
        XCTAssertEqual(signer.label, "software")
    }
}
