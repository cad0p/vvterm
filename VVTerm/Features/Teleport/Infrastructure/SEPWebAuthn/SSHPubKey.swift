// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SSHPubKey.swift
//  SEPWebAuthn
//
//  Pure-Swift ed25519 SSH public key generation — no `ssh-keygen` / `Process`
//  dependency, so the same code runs on macOS (CLI) and iOS (app). Used by
//  both the session 1.5/1.6b Mac CLI and the session 1.6b Option A iOS app,
//  so the OpenSSH wire format is provably identical across both paths.
//
//  Generates a fresh Curve25519 ed25519 keypair via CryptoKit, emits the
//  public key in OpenSSH authorized_keys format:
//
//      ssh-ed25519 <base64(wire)> <comment>
//
//  where wire = uint32_be(len("ssh-ed25519")) || "ssh-ed25519"
//             || uint32_be(len(pubkey))      || pubkey(32 bytes)
//
//  The private key is discarded — the spike only POSTs the pub key to
//  /webapi/mfa/login/finish (the cert subject). Production (session 2.2)
//  will keep the private key for the actual SSH connection.
//
//  This replaces the macOS CLI's prior `Process`/`ssh-keygen` shell-out
//  (PR #18 era) and the iOS app's duplicate `beUInt32` helper (PR #22),
//  consolidating both into a single source of truth.

import Foundation
import CryptoKit

public enum SSHPubKey {
    /// Generate a fresh ed25519 keypair and return the OpenSSH authorized_keys
    /// string for the public key.
    ///
    /// - Parameter comment: the comment field (defaults to "sep-spike").
    /// - Returns: e.g. `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... sep-spike"`
    public static func generateEd25519AuthorizedKeys(comment: String = "sep-spike") -> String {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation  // 32 bytes

        var wire = Data()
        let alg = Data("ssh-ed25519".utf8)
        wire.append(beUInt32(UInt32(alg.count)))
        wire.append(alg)
        wire.append(beUInt32(UInt32(pub.count)))
        wire.append(pub)
        let b64 = wire.base64EncodedString()
        return "ssh-ed25519 \(b64) \(comment)"
    }

    /// Generate a fresh ed25519 keypair and return BOTH the OpenSSH
    /// authorized_keys public key string AND the OpenSSH PEM private key.
    ///
    /// The private key is formatted in the `openssh-key-v1` PEM format
    /// (unencrypted, cipher=none, kdf=none) — the same format
    /// `ssh-keygen -t ed25519` produces and `libssh2_userauth_publickey_frommemory`
    /// accepts. Used by the Teleport coordinators (Phase 1 bootstrap + Phase 3
    /// login) to retain the private key for the SSH connection (the cert is
    /// issued against the public key; the private key proves ownership).
    ///
    /// - Parameter comment: the comment field (defaults to "sep-spike").
    /// - Returns: a tuple of (authorized_keys public string, OpenSSH PEM private key string).
    public static func generateEd25519KeyPair(comment: String = "sep-spike") -> (publicKey: String, privateKeyPEM: String) {
        let priv = Curve25519.Signing.PrivateKey()
        let pub = priv.publicKey.rawRepresentation  // 32 bytes
        let privRaw = priv.rawRepresentation           // 32 bytes

        // Public key in authorized_keys format.
        var wire = Data()
        let alg = Data("ssh-ed25519".utf8)
        wire.append(beUInt32(UInt32(alg.count)))
        wire.append(alg)
        wire.append(beUInt32(UInt32(pub.count)))
        wire.append(pub)
        let pubB64 = wire.base64EncodedString()
        let publicKey = "ssh-ed25519 \(pubB64) \(comment)"

        // Private key in OpenSSH PEM format (openssh-key-v1, unencrypted).
        let privateKeyPEM = formatEd25519PrivateKeyPEM(
            publicKey: pub,
            privateKey: privRaw,
            comment: comment
        )
        return (publicKey, privateKeyPEM)
    }

    /// Format an ed25519 keypair as an OpenSSH PEM private key
    /// (`-----BEGIN OPENSSH PRIVATE KEY-----`). Unencrypted (cipher=none,
    /// kdf=none). Mirrors `ssh-keygen -t ed25519` output.
    ///
    /// The `openssh-key-v1` format:
    ///   "openssh-key-v1\0"
    ///   || sshString("none")        // cipher
    ///   || sshString("none")        // kdf
    ///   || sshString("")            // kdf options (empty)
    ///   || uint32BE(1)               // number of keys
    ///   || sshString(publicBlob)     // public key blob
    ///   || sshString(privateSection) // private section (checkint + keys + comment + padding)
    ///
    /// where publicBlob  = sshString("ssh-ed25519") || sshString(pubKey)
    ///   and privateSection = checkInt(4) || checkInt(4) || sshString("ssh-ed25519")
    ///                        || sshString(pubKey) || sshString(privKey||pubKey)
    ///                        || sshString(comment) || padding
    ///
    /// Ed25519 private key in OpenSSH is 64 bytes: private (32) || public (32).
    private static func formatEd25519PrivateKeyPEM(
        publicKey: Data,
        privateKey: Data,
        comment: String
    ) -> String {
        // Public key blob: sshString("ssh-ed25519") || sshString(pubKey)
        var publicBlob = Data()
        publicBlob.append(sshString("ssh-ed25519"))
        publicBlob.append(sshString(publicKey))

        // Private section: checkint (random, repeated) + keytype + pubkey + privkey + comment + padding
        let checkInt = UInt32.random(in: 0..<UInt32.max)
        var privateSection = Data()
        privateSection.append(uint32BE(checkInt))
        privateSection.append(uint32BE(checkInt))
        privateSection.append(sshString("ssh-ed25519"))
        privateSection.append(sshString(publicKey))
        // Ed25519 private key in OpenSSH is 64 bytes: private (32) || public (32)
        var fullPrivateKey = Data(privateKey)
        fullPrivateKey.append(publicKey)
        privateSection.append(sshString(fullPrivateKey))
        privateSection.append(sshString(comment))

        // Pad to block size (8 for unencrypted). Padding bytes are 1, 2, 3, ...
        let blockSize = 8
        let currentMod = privateSection.count % blockSize
        if currentMod != 0 {
            let needed = blockSize - currentMod
            for i in 1...needed {
                privateSection.append(UInt8(i))
            }
        }

        // Full key blob.
        var keyBlob = Data()
        keyBlob.append("openssh-key-v1".data(using: .utf8)!)
        keyBlob.append(0) // null terminator
        keyBlob.append(sshString("none")) // cipher
        keyBlob.append(sshString("none")) // kdf
        keyBlob.append(sshString(Data())) // kdf options (empty)
        keyBlob.append(uint32BE(1)) // number of keys
        keyBlob.append(sshString(publicBlob)) // public key
        keyBlob.append(sshString(privateSection)) // private section

        // Base64 encode + PEM-wrap (70-char lines, matching ssh-keygen).
        let base64 = keyBlob.base64EncodedString()
        let wrapped = wrapBase64(base64, lineLength: 70)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(wrapped)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// SSH wire helper: uint32 length prefix + payload.
    private static func sshString(_ string: String) -> Data {
        sshString(Data(string.utf8))
    }

    private static func sshString(_ data: Data) -> Data {
        var result = Data()
        result.append(uint32BE(UInt32(data.count)))
        result.append(data)
        return result
    }

    /// Big-endian uint32 → 4 bytes.
    private static func uint32BE(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    /// Wrap a base64 string into fixed-length lines.
    private static func wrapBase64(_ string: String, lineLength: Int) -> String {
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let endIndex = string.index(index, offsetBy: lineLength, limitedBy: string.endIndex) ?? string.endIndex
            if !result.isEmpty {
                result += "\n"
            }
            result += String(string[index..<endIndex])
            index = endIndex
        }
        return result
    }
}

/// Big-endian uint32 → 4 bytes, host-endianness-independent.
///
/// Shifting `value >> 24` always yields the most-significant byte regardless
/// of host endianness, so this is correct on both arm64 (LE) and any future
/// BE arch. This is the correct pattern — do NOT use `self.bigEndian` then
/// shift (that double-swaps on LE and emits little-endian bytes; see the
/// `CBOR.swift` `bigEndianBytes` bug for the cautionary tale).
private func beUInt32(_ value: UInt32) -> Data {
    var out = Data(count: 4)
    out[0] = UInt8(truncatingIfNeeded: value >> 24)
    out[1] = UInt8(truncatingIfNeeded: value >> 16)
    out[2] = UInt8(truncatingIfNeeded: value >> 8)
    out[3] = UInt8(truncatingIfNeeded: value & 0xff)
    return out
}
