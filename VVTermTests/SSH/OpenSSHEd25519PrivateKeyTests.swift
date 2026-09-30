// SPDX-License-Identifier: MIT
//
//  OpenSSHEd25519PrivateKeyTests.swift
//  VVTermTests
//
//  Coverage for the `openssh-key-v1` ed25519 private key parser (#269).
//
//  The parser gates the agent's signing key: it must accept exactly the PEM
//  `SSHPubKey.generateEd25519KeyPair` writes for the stored Teleport key,
//  derive the same public key the certificate carries, and reject every
//  malformed variant (encrypted, multi-key, bad checkint, mismatch, trailing
//  bytes) so a corrupted key is never served as an agent.
//

import CryptoKit
import Foundation
import Testing
@testable import VVTerm

struct OpenSSHEd25519PrivateKeyTests {

    // MARK: - Fixtures

    /// Decode a PEM body into the raw `openssh-key-v1` blob.
    private func decodePEMBody(_ pem: String) throws -> Data {
        let body = pem
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return try #require(Data(base64Encoded: body))
    }

    private func makeFixture(comment: String = "vvterm-test") throws -> (pem: String, publicLine: String, blob: Data) {
        let pair = SSHPubKey.generateEd25519KeyPair(comment: comment)
        return (pair.privateKeyPEM, pair.publicKey, try decodePEMBody(pair.privateKeyPEM))
    }

    private func mutate(_ blob: Data, at offset: Int, to byte: UInt8) -> Data {
        var copy = blob
        copy[copy.startIndex + offset] = byte
        return copy
    }

    /// Complement the byte at `offset`. Unlike a constant `mutate`, this is
    /// *provably* a change (`b ^ 0xFF != b`), so a test that corrupts a
    /// **random** fixture byte cannot silently no-op on the 1-in-256 runs
    /// where the constant already equals it (issue #306).
    private func flip(_ blob: Data, at offset: Int) -> Data {
        var copy = blob
        let index = copy.startIndex + offset
        copy[index] = copy[index] ^ 0xFF
        return copy
    }

    /// Offset of the private section's first checkint in the blob.
    private func privateSectionOffset(in blob: Data) throws -> Int {
        let publicKeyBlobLength = try #require(SSHAgentProtocolCodec.readUInt32(blob, at: 39))
        return 43 + Int(publicKeyBlobLength) + 4
    }

    // MARK: - Round trip

    @Test
    func parsesThePEMTheFormatterWrites() throws {
        let fixture = try makeFixture()
        let key = try OpenSSHEd25519PrivateKey.parse(pemData: Data(fixture.pem.utf8))

        let (_, expectedBlob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(fixture.publicLine))
        #expect(key.publicKeyBlob == expectedBlob)
        #expect(key.publicKeyRaw.count == 32)
    }

    @Test
    func derivedPublicKeyMatchesTheCertificateCarriedBlob() throws {
        // The serving layer's check: `key.publicKeyBlob == cert.publicKeyBlob`
        // is exactly what `TeleportAgentIdentity` compares before serving.
        let fixture = try makeFixture()
        let key = try OpenSSHEd25519PrivateKey.parse(pem: fixture.pem)
        let (_, certBlob) = try #require(OpenSSHCertificate.parseAuthorizedKeysLine(fixture.publicLine))
        #expect(key.publicKeyBlob == certBlob)
    }

    @Test
    func signatureVerifiesWithTheDerivedPublicKey() throws {
        let fixture = try makeFixture()
        let key = try OpenSSHEd25519PrivateKey.parse(pem: fixture.pem)

        // Extract the raw 32-byte public key from the wire blob:
        // string("ssh-ed25519") || string(pub32).
        let keyOffset = 4 + "ssh-ed25519".utf8.count
        let publicKeyLength = try #require(SSHAgentProtocolCodec.readUInt32(key.publicKeyBlob, at: keyOffset))
        #expect(Int(publicKeyLength) == 32)
        let rawOffset = keyOffset + 4
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: key.publicKeyBlob.subdata(in: rawOffset..<(rawOffset + 32))
        )

        let data = Data("a session id the node asked us to sign".utf8)
        let signature = try #require(key.signature(for: data))
        #expect(signature.count == 64)
        #expect(publicKey.isValidSignature(signature, for: data))
    }

    // MARK: - Rejections

    @Test
    func rejectsAnUnsupportedCipher() throws {
        let fixture = try makeFixture()
        // Flip the first byte of the cipher string ("none" -> "xone"); the
        // cipher-length field is untouched, so this is a pure content change.
        let blob = mutate(fixture.blob, at: 19, to: 0x78)
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.cipherNotSupported) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsAnUnsupportedKDF() throws {
        let fixture = try makeFixture()
        let blob = mutate(fixture.blob, at: 27, to: 0x78)
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.kdfNotSupported) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsMoreThanOneKey() throws {
        let fixture = try makeFixture()
        let blob = mutate(fixture.blob, at: 38, to: 0x02)
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.keyCountUnsupported) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsMismatchedCheckints() throws {
        let fixture = try makeFixture()
        let offset = try privateSectionOffset(in: fixture.blob)
        // Complement, not a constant: the fixture's checkint is random, so
        // writing a fixed byte is a no-op on the 1-in-256 runs where it
        // already equals that value, and the blob then parses clean (#306).
        // `b ^ 0xFF != b` makes the corruption provable; the assertion below
        // names a future no-op instead of letting it surface as a parse pass.
        let blob = flip(fixture.blob, at: offset + 4)
        #expect(blob != fixture.blob, "the checkint corruption must change the blob")
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.checkIntMismatch) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsAMismatchedEmbeddedPublicKey() throws {
        let fixture = try makeFixture()
        let offset = try privateSectionOffset(in: fixture.blob)
        // Private section layout: checkint×2 (8) + type string (4+11) +
        // string pub (4+32) — flip a byte inside the embedded pub.
        let embeddedPublicKey = offset + 8 + 4 + 11 + 4
        // The embedded public key is random, so this must be a complement
        // rather than a constant (#306).
        let blob = flip(fixture.blob, at: embeddedPublicKey)
        #expect(blob != fixture.blob, "the embedded-public-key corruption must change the blob")
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.publicKeyMismatch) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsASeedThatDoesNotDeriveTheAdvertisedPublicKey() throws {
        let fixture = try makeFixture()
        let offset = try privateSectionOffset(in: fixture.blob)
        // Private section layout: checkint×2 + type string + pub string, then
        // string(priv32 || pub32). Flip a seed byte (the first 32 bytes); the
        // embedded public halves stay consistent, so only the re-derivation
        // catches the mismatch.
        let seed = offset + 8 + 4 + 11 + 4 + 32 + 4
        // The seed is random, so this must be a complement rather than a
        // constant (#306). A changed seed always re-derives a different
        // public key, which is exactly what this test needs.
        let blob = flip(fixture.blob, at: seed)
        #expect(blob != fixture.blob, "the seed corruption must change the blob")
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.publicKeyMismatch) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsTrailingBytes() throws {
        let fixture = try makeFixture()
        let blob = fixture.blob + Data([0xAA])
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.trailingBytes) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsAnInvalidMagic() throws {
        let fixture = try makeFixture()
        let blob = mutate(fixture.blob, at: 0, to: 0x00)
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.invalidMagic) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }

    @Test
    func rejectsNonPEMInput() {
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.invalidPEM) {
            try OpenSSHEd25519PrivateKey.parse(pem: "ssh-ed25519 AAAAC3Nza...")
        }
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.invalidPEM) {
            try OpenSSHEd25519PrivateKey.parse(
                pem: "-----BEGIN OPENSSH PRIVATE KEY-----\nnot base64!!!\n-----END OPENSSH PRIVATE KEY-----"
            )
        }
    }

    @Test
    func rejectsATruncatedBlob() throws {
        let fixture = try makeFixture()
        let blob = fixture.blob.prefix(fixture.blob.count - 8)
        #expect(throws: OpenSSHEd25519PrivateKey.ParseError.malformed) {
            try OpenSSHEd25519PrivateKey.parse(blob: blob)
        }
    }
}
