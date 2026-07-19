//
//  TeleportKeyGeneration.swift
//  VVTerm
//
//  Client-side keypair generation for Teleport passwordless login.
//  Suite `balanced-v1` (pcad.it default): ed25519 (SSH) + ECDSA-P256 (TLS).
//
//  SSH pubkey format: OpenSSH authorized_keys  ("ssh-ed25519 <base64-blob> <comment>")
//  TLS pubkey format: PEM PKIX SubjectPublicKeyInfo  ("-----BEGIN PUBLIC KEY-----")
//
//  Go reference: lib/client/api.go MarshalSSHPublicKey (~:4162),
//               lib/client/weblogin.go UserPublicKeys (~:237).
//

import Foundation
import CryptoKit

enum TeleportKeyGenerationError: LocalizedError {
    case serializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .serializationFailed(let detail):
            return "Teleport key serialization failed: \(detail)"
        }
    }
}

enum TeleportKeyGenerator {

    struct GeneratedKeyPair {
        /// ed25519 private key in OpenSSH PEM format (for libssh2 cert auth later).
        let sshPrivateKeyPEM: Data
        /// ed25519 public key in OpenSSH authorized_keys format (sent to server in /finish).
        let sshPublicKeyAuthorized: String

        /// ECDSA-P256 private key in PEM PKCS#8 (unused in V1; stored for V2 gRPC).
        let tlsPrivateKeyPEM: Data
        /// ECDSA-P256 public key in PEM PKIX (sent to server in /finish).
        let tlsPublicKeyPEM: String
    }

    /// Generate a fresh keypair for the given suite.
    /// `sshComment` is appended to the SSH public key (convention: user@host).
    static func generate(suite: TeleportSignatureSuite, sshComment: String) throws -> GeneratedKeyPair {
        switch suite {
        case .balancedV1, .fipsV1:
            return try generateBalancedV1(sshComment: sshComment)
        case .legacy:
            // pcad.it is balanced-v1; legacy (RSA) is not expected. If ever needed,
            // VVTerm's SSHKeyGenerator already produces RSA keys, but Teleport's
            // legacy suite uses RSA-2048 specifically. Defer until needed.
            throw TeleportKeyGenerationError.serializationFailed("legacy suite (RSA-2048) not implemented; pcad.it is balanced-v1")
        }
    }

    // MARK: - balanced-v1: ed25519 (SSH) + ECDSA-P256 (TLS)

    private static func generateBalancedV1(sshComment: String) throws -> GeneratedKeyPair {
        let sshPriv = Curve25519.Signing.PrivateKey()
        let sshPub = sshPriv.publicKey

        let tlsPriv = P256.Signing.PrivateKey()
        let tlsPub = tlsPriv.publicKey

        // SSH private key in OpenSSH PEM format (reuses VVTerm's proven serializer).
        let sshPrivateKeyPEMString = formatEd25519PrivateKeyPEM(sshPriv, comment: sshComment)
        guard let sshPrivateKeyPEM = sshPrivateKeyPEMString.data(using: .utf8) else {
            throw TeleportKeyGenerationError.serializationFailed("ed25519 private key UTF-8 encoding")
        }

        // SSH public key in authorized_keys format: "ssh-ed25519 <base64-blob> <comment>"
        let sshPublicKeyAuthorized = formatEd25519PublicKeyAuthorized(sshPub, comment: sshComment)

        // TLS private key in PKCS#8 PEM. P256.Signing.PrivateKey provides DER via .x963Representation,
        // but PKCS#8 wraps the EC private key. Use SecKey to export PKCS#8.
        let tlsPrivateKeyPEM = try exportP256PrivateKeyPKCS8PEM(tlsPriv)

        // TLS public key in PEM PKIX (SubjectPublicKeyInfo).
        let tlsPublicKeyPEM = try formatP256PublicKeyPKIXPEM(tlsPub)

        return GeneratedKeyPair(
            sshPrivateKeyPEM: sshPrivateKeyPEM,
            sshPublicKeyAuthorized: sshPublicKeyAuthorized,
            tlsPrivateKeyPEM: tlsPrivateKeyPEM,
            tlsPublicKeyPEM: tlsPublicKeyPEM
        )
    }

    // MARK: - SSH ed25519 OpenSSH formats

    private static func formatEd25519PrivateKeyPEM(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        // Reuse VVTerm's existing, proven OpenSSH private key formatter by going through
        // SSHKeyGenerator (which produces the exact openssh-key-v1 wire format).
        // SSHKeyGenerator.generate produces a fresh key, but we need to format OUR key —
        // so inline the OpenSSH PEM format using the same approach.
        // (SSHKeyGenerator doesn't expose a formatter that takes an existing key, so we
        // reproduce the minimal openssh-key-v1 encoding here.)
        return formatOpenSSHPrivateKeyPEM(key, comment: comment)
    }

    private static func formatEd25519PublicKeyAuthorized(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        // Blob: string("ssh-ed25519") + string(32-byte pubkey)
        var blob = Data()
        blob.append(sshString("ssh-ed25519"))
        blob.append(sshString(key.rawRepresentation))
        let base64 = blob.base64EncodedString()
        return comment.isEmpty ? "ssh-ed25519 \(base64)" : "ssh-ed25519 \(base64) \(comment)"
    }

    // MARK: - ECDSA-P256 PEM formats

    private static func formatP256PublicKeyPKIXPEM(_ key: P256.Signing.PublicKey) throws -> String {
        // .x963Representation is the SEC1 EC point. We need DER SubjectPublicKeyInfo (PKIX),
        // which is: SEQUENCE { AlgorithmIdentifier, BIT STRING { EC point } }.
        // For P-256 the AlgorithmIdentifier is a fixed prefix (1.2.840.10045.2.1 ecPublicKey + 1.2.840.10045.3.1.7 prime256v1).
        let ecPoint = key.x963Representation

        // Fixed SPKI prefix for P-256 ECDSA public key (26 bytes).
        // SEQUENCE { SEQUENCE { OID 1.2.840.10045.2.1 (ecPublicKey), OID 1.2.840.10045.3.1.7 (prime256v1) }, BIT STRING { 0x00, ecPoint } }
        let spkiPrefix: [UInt8] = [
            0x30, 0x59, // SEQUENCE, length 89
            0x30, 0x13, //   SEQUENCE, length 19
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID 1.2.840.10045.2.1
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID 1.2.840.10045.3.1.7
            0x03, 0x42, 0x00, // BIT STRING, length 66, 0 unused bits
        ]

        var der = Data(spkiPrefix)
        der.append(ecPoint)

        let base64 = der.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 64)
        return "-----BEGIN PUBLIC KEY-----\n\(wrapped)\n-----END PUBLIC KEY-----"
    }

    private static func exportP256PrivateKeyPKCS8PEM(_ key: P256.Signing.PrivateKey) throws -> Data {
        // Create a SecKey from the raw representation and export as PKCS#8.
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        // P256.Signing.PrivateKey.derRepresentation produces the SEC1 ECPrivateKey DER.
        // SecKeyCreateWithData wants the SEC1 representation for EC keys.
        guard let secKey = SecKeyCreateWithData(key.derRepresentation as CFData, attributes as CFDictionary, &error) else {
            throw TeleportKeyGenerationError.serializationFailed("SecKey EC private key creation failed")
        }

        // Export as PKCS#8 (kSecAttrKeyFormatPKCS8 not directly available; copy external representation
        // gives SEC1 for EC private keys, so we wrap it ourselves).
        guard let sec1Data = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw TeleportKeyGenerationError.serializationFailed("SecKey EC export failed")
        }

        // Wrap SEC1 EC private key into PKCS#8 PrivateKeyInfo.
        // PrivateKeyInfo ::= SEQUENCE { version 0, AlgorithmIdentifier, OCTET STRING { SEC1 key } }
        let pkcs8 = wrapSEC1InPKCS8(sec1Data)
        let base64 = pkcs8.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 64)
        let pem = "-----BEGIN PRIVATE KEY-----\n\(wrapped)\n-----END PRIVATE KEY-----\n"
        return pem.data(using: .utf8) ?? Data()
    }

    /// Wrap a SEC1 ECPrivateKey DER into PKCS#8 PrivateKeyInfo DER.
    private static func wrapSEC1InPKCS8(_ sec1: Data) -> Data {
        // AlgorithmIdentifier for ECDSA P-256: SEQUENCE { OID 1.2.840.10045.2.1, OID 1.2.840.10045.3.1.7 }
        let algID: [UInt8] = [
            0x30, 0x13, // SEQUENCE, length 19
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // OID 1.2.840.10045.2.1
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID 1.2.840.10045.3.1.7
        ]

        // OCTET STRING wrapping the SEC1 key
        let octetString = derTLV(tag: 0x04, content: sec1)

        // PrivateKeyInfo: SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING }
        let version: [UInt8] = [0x02, 0x01, 0x00] // INTEGER 0
        var inner = Data(version)
        inner.append(Data(algID))
        inner.append(octetString)
        return derTLV(tag: 0x30, content: inner)
    }

    // MARK: - DER / SSH wire helpers

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        if content.count < 0x80 {
            result.append(UInt8(content.count))
        } else {
            // Long-form length
            var len = content.count
            var lenBytes: [UInt8] = []
            while len > 0 {
                lenBytes.insert(UInt8(len & 0xFF), at: 0)
                len >>= 8
            }
            result.append(UInt8(0x80 | lenBytes.count))
            result.append(contentsOf: lenBytes)
        }
        result.append(content)
        return result
    }

    private static func sshString(_ string: String) -> Data {
        let bytes = string.data(using: .utf8) ?? Data()
        return sshString(bytes)
    }

    private static func sshString(_ data: Data) -> Data {
        var result = Data()
        result.append(uint32BE(UInt32(data.count)))
        result.append(data)
        return result
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    private static func wrapBase64(_ string: String, lineLength: Int) -> String {
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let endIndex = string.index(index, offsetBy: lineLength, limitedBy: string.endIndex) ?? string.endIndex
            if !result.isEmpty { result += "\n" }
            result += String(string[index..<endIndex])
            index = endIndex
        }
        return result
    }
}

// MARK: - OpenSSH private key PEM (openssh-key-v1) for an existing ed25519 key

extension TeleportKeyGenerator {
    /// Format an existing ed25519 private key as an OpenSSH PEM (openssh-key-v1).
    /// Mirrors SSHKeyGenerator's formatter but accepts a caller-provided key.
    private static func formatOpenSSHPrivateKeyPEM(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let publicKeyBytes = key.publicKey.rawRepresentation
        let privateKeyBytes = key.rawRepresentation

        // Public key blob: string("ssh-ed25519") + string(32-byte pubkey)
        var publicBlob = Data()
        publicBlob.append(sshString("ssh-ed25519"))
        publicBlob.append(sshString(publicKeyBytes))

        // Private section: checkint (repeated) + keytype + pubkey + privkey(64) + pubkey + comment + padding
        let checkInt = UInt32.random(in: 0..<UInt32.max)
        var privateSection = Data()
        privateSection.append(uint32BE(checkInt))
        privateSection.append(uint32BE(checkInt))
        privateSection.append(sshString("ssh-ed25519"))
        privateSection.append(sshString(publicKeyBytes))
        // OpenSSH ed25519 private key is 64 bytes: private(32) + public(32)
        var fullPrivateKey = Data(privateKeyBytes)
        fullPrivateKey.append(publicKeyBytes)
        privateSection.append(sshString(fullPrivateKey))
        privateSection.append(sshString(comment))

        // Pad to 8-byte block boundary (unencrypted)
        let blockSize = 8
        let currentMod = privateSection.count % blockSize
        if currentMod != 0 {
            let needed = blockSize - currentMod
            for i in 1...needed {
                privateSection.append(UInt8(i))
            }
        }

        var keyBlob = Data()
        keyBlob.append("openssh-key-v1".data(using: .utf8)!)
        keyBlob.append(0) // null terminator
        keyBlob.append(sshString("none")) // cipher
        keyBlob.append(sshString("none")) // kdf
        keyBlob.append(sshString(Data())) // kdf options (empty)
        keyBlob.append(uint32BE(1)) // number of keys
        keyBlob.append(sshString(publicBlob))
        keyBlob.append(sshString(privateSection))

        let base64 = keyBlob.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 70)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
