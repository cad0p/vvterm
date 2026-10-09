// SPDX-License-Identifier: MIT
//
//  OpenSSHEd25519PrivateKey.swift
//  VVTerm
//
//  Parser for the unencrypted `openssh-key-v1` ed25519 private key format
//  (`-----BEGIN OPENSSH PRIVATE KEY-----`), the form `ssh-keygen -t ed25519`
//  produces and the package's `TeleportCore.SSHPubKey.formatEd25519PrivateKeyPEM`
//  writes for the stored Teleport key (the generation side lives in the
//  `cad0p/swift-teleport` package, `Sources/TeleportCore/Infrastructure/SEPWebAuthn/`;
//  this is the inverse). The host test-support copy of the generator is
//  `VVTermTests/SSH/SSHPubKeyTestSupport.swift`.
//
//  Why it exists: the Teleport proxy-recording path (#269) must sign the
//  proxy's agent requests with the exact key pair whose certificate the app
//  already holds, without a Keychain read on the sign path. The parser
//  validates the whole structure and re-derives the public key from the
//  seed, so a corrupted or mismatched key can never be served as an agent.
//
//  Format (PROTOCOL.key, unencrypted):
//
//      "openssh-key-v1\0"
//      || string("none")            // cipher
//      || string("none")            // kdf
//      || string("")                // kdf options
//      || uint32(1)                 // number of keys
//      || string(public key blob)   // string("ssh-ed25519") || string(pub32)
//      || string(private section)
//      || [1, 2, 3, …]              // padding
//
//  where the private section is:
//
//      checkint(4) || checkint(4)
//      || string("ssh-ed25519")
//      || string(pub32)
//      || string(priv32 || pub32)
//      || string(comment)
//      || 1, 2, 3, …                // padding to the 8-byte block size
//
//  Contract: cipher/kdf must be "none", the key count must be 1, the two
//  checkints must match, every declared length must fit its enclosing blob,
//  the private section's embedded public key must equal the outer public key,
//  the re-derived public key must equal both, and there must be no trailing
//  bytes. Anything else throws — the caller serves no agent.
//
//  No zeroization is claimed: `Data`/CryptoKit copies cannot be reliably
//  zeroized. The key is held in memory for the session's lifetime and
//  released on teardown like the rest of the session state.

import CryptoKit
import Foundation

struct OpenSSHEd25519PrivateKey: Sendable, Equatable {
    /// The 32-byte ed25519 public key.
    let publicKeyRaw: Data
    /// The 32-byte ed25519 seed (the private key half whose wire form is
    /// `seed || publicKey`).
    private let seed: Data

    /// The `ssh-ed25519` wire blob for `publicKeyRaw` — the same bytes as
    /// `OpenSSHCertificate.publicKeyBlob` for a matching certificate.
    var publicKeyBlob: Data {
        var blob = Self.sshString(Data("ssh-ed25519".utf8))
        blob.append(Self.sshString(publicKeyRaw))
        return blob
    }

    /// `uint32_be(length) || payload`. Local SSH wire helper: this Core/SSH
    /// parser must not reach into `Features/Teleport`'s `OpenSSHCertificate`.
    private static func sshString(_ data: Data) -> Data {
        var out = Data(capacity: 4 + data.count)
        let length = UInt32(data.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(data)
        return out
    }

    /// Raw 64-byte ed25519 signature over `data`, or nil when signing fails
    /// (the seed was validated at parse time, so this is effectively
    /// unreachable).
    func signature(for data: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            return nil
        }
        return try? key.signature(for: data)
    }

    enum ParseError: Error, Equatable {
        /// Not a `-----BEGIN OPENSSH PRIVATE KEY-----` block, or the body is
        /// not valid base64.
        case invalidPEM
        /// The decoded blob does not start with `openssh-key-v1\0`.
        case invalidMagic
        /// Cipher other than `none` (an encrypted key) — never supported.
        case cipherNotSupported
        /// KDF other than `none`.
        case kdfNotSupported
        /// Non-empty KDF options.
        case kdfOptionsNotSupported
        /// Key count other than 1.
        case keyCountUnsupported
        /// A declared string/field length runs past the end of its enclosing
        /// blob, the ed25519 field sizes are wrong, or the private-section
        /// padding is malformed.
        case malformed
        /// The two private-section checkints differ (wrong key/passphrase).
        case checkIntMismatch
        /// The public key in the private section and/or the public key
        /// re-derived from the seed does not match the outer public key.
        case publicKeyMismatch
        /// Bytes remain after the private key section.
        case trailingBytes
    }

    // MARK: - Parsing

    static func parse(pem: String) throws -> OpenSSHEd25519PrivateKey {
        try parse(pemData: Data(pem.utf8))
    }

    static func parse(pemData: Data) throws -> OpenSSHEd25519PrivateKey {
        guard let blob = decodePEM(pemData) else {
            throw ParseError.invalidPEM
        }
        return try parse(blob: blob)
    }

    /// Decode the PEM armor and return the `openssh-key-v1` blob.
    private static func decodePEM(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let endMarker = "-----END OPENSSH PRIVATE KEY-----"
        guard let beginRange = text.range(of: beginMarker),
              let endRange = text.range(of: endMarker),
              beginRange.upperBound <= endRange.lowerBound else {
            return nil
        }
        let body = text[beginRange.upperBound..<endRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }

    static func parse(blob: Data) throws -> OpenSSHEd25519PrivateKey {
        var reader = BlobReader(data: blob)

        guard reader.readBytes(count: blobMagic.count) == blobMagic else {
            throw ParseError.invalidMagic
        }
        guard let cipher = reader.readASCIIString() else { throw ParseError.malformed }
        guard cipher == "none" else { throw ParseError.cipherNotSupported }
        guard let kdf = reader.readASCIIString() else { throw ParseError.malformed }
        guard kdf == "none" else { throw ParseError.kdfNotSupported }
        guard let kdfOptions = reader.readString() else { throw ParseError.malformed }
        guard kdfOptions.isEmpty else { throw ParseError.kdfOptionsNotSupported }
        guard let keyCount = reader.readUInt32() else { throw ParseError.malformed }
        guard keyCount == 1 else { throw ParseError.keyCountUnsupported }

        guard let publicKeyBlob = reader.readString() else { throw ParseError.malformed }
        guard let (outerType, outerPublicKey) = Self.parsePublicKeyBlob(publicKeyBlob),
              outerType == "ssh-ed25519" else {
            throw ParseError.malformed
        }

        guard let privateSection = reader.readString() else { throw ParseError.malformed }
        guard reader.remaining == 0 else { throw ParseError.trailingBytes }

        var section = BlobReader(data: privateSection)
        guard let checkInt1 = section.readUInt32(),
              let checkInt2 = section.readUInt32() else {
            throw ParseError.malformed
        }
        guard checkInt1 == checkInt2 else { throw ParseError.checkIntMismatch }

        guard let sectionType = section.readASCIIString(), sectionType == "ssh-ed25519" else {
            throw ParseError.malformed
        }
        guard let sectionPublicKey = section.readString(),
              sectionPublicKey == outerPublicKey else {
            throw ParseError.publicKeyMismatch
        }
        guard let privateKey = section.readString(), privateKey.count == 64 else {
            throw ParseError.malformed
        }
        // OpenSSH ed25519 stores `seed(32) || publicKey(32)`; the trailing
        // half must repeat the advertised public key.
        guard privateKey.suffix(32) == outerPublicKey else {
            throw ParseError.publicKeyMismatch
        }
        guard section.readString() != nil else { throw ParseError.malformed }  // comment
        guard Self.isValidPadding(section.remainingBytes) else { throw ParseError.malformed }

        let seed = Data(privateKey.prefix(32))
        guard let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
              derived.publicKey.rawRepresentation == outerPublicKey else {
            throw ParseError.publicKeyMismatch
        }

        return OpenSSHEd25519PrivateKey(publicKeyRaw: outerPublicKey, seed: seed)
    }

    /// Split an SSH public key blob into its type and raw key bytes, requiring
    /// the ed25519 32-byte key shape.
    private static func parsePublicKeyBlob(_ blob: Data) -> (type: String, key: Data)? {
        var reader = BlobReader(data: blob)
        guard let type = reader.readASCIIString(),
              let key = reader.readString(),
              key.count == 32,
              reader.remaining == 0 else {
            return nil
        }
        return (type, key)
    }

    /// Unencrypted private sections pad with `1, 2, 3, …` to the 8-byte
    /// block size, so the trailing bytes are a prefix of the natural sequence.
    private static func isValidPadding(_ padding: Data) -> Bool {
        guard padding.count < 8 else { return false }
        for (index, byte) in padding.enumerated() where byte != UInt8(index + 1) {
            return false
        }
        return true
    }

    private static let blobMagic = Data([UInt8]("openssh-key-v1".utf8) + [0])

    // MARK: - Blob reading

    private struct BlobReader {
        let data: Data
        private(set) var offset = 0

        var remaining: Int { data.count - offset }
        var remainingBytes: Data {
            remaining > 0 ? Data(data[(data.startIndex + offset)...]) : Data()
        }

        mutating func readUInt32() -> UInt32? {
            guard let value = SSHAgentProtocolCodec.readUInt32(data, at: offset) else { return nil }
            offset += 4
            return value
        }

        mutating func readBytes(count: Int) -> Data? {
            guard count >= 0, remaining >= count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return Data(data[start..<(start + count)])
        }

        mutating func readString() -> Data? {
            guard let length = readUInt32() else { return nil }
            let count = Int(length)
            guard count <= remaining else { return nil }
            let start = data.startIndex + offset
            offset += count
            return Data(data[start..<(start + count)])
        }

        mutating func readASCIIString() -> String? {
            guard let bytes = readString() else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
