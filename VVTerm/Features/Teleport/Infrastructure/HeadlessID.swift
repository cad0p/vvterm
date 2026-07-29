// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HeadlessID.swift
//  VVTerm
//
//  Port of Teleport's `services.NewHeadlessAuthenticationID`
//  (lib/services/headlessauthn.go:57) to Swift. This is the deterministic
//  ID derived from the SSH public key that identifies the headless auth
//  request on both the client (POST /webapi/headless/login) and the web
//  approval page (/web/headless/<id>).
//
//  The Go implementation:
//
//      func NewHeadlessAuthenticationID(pubKey []byte) string {
//          return uuid.NewHash(sha256.New(), uuid.Nil, pubKey, 5).String()
//      }
//
//  where `uuid.NewHash` (google/uuid v1.6.0, hash.go) is:
//
//      func NewHash(h hash.Hash, space UUID, data []byte, version int) UUID {
//          h.Reset()
//          h.Write(space[:]) // uuid.Nil = 16 zero bytes
//          h.Write(data)     // the SSH public key bytes
//          s := h.Sum(nil)
//          var uuid UUID
//          copy(uuid[:], s)
//          uuid[6] = (uuid[6] & 0x0f) | uint8((version&0xf)<<4) // version 5
//          uuid[8] = (uuid[8] & 0x3f) | 0x80                     // RFC 9562 variant
//          return uuid
//      }
//
//  So the algorithm is:
//    1. SHA256(uuid.Nil (16 zero bytes) || pubKey)
//    2. Take the first 16 bytes of the digest.
//    3. Set byte[6] = (byte[6] & 0x0f) | 0x50  (version = 5)
//    4. Set byte[8] = (byte[8] & 0x3f) | 0x80  (RFC 9562 variant)
//    5. Format as a UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
//
//  The `pubKey` bytes are the output of `ssh.MarshalAuthorizedKey()` — the
//  OpenSSH authorized_keys format: "ssh-ed25519 <base64> <comment>\n" (with
//  a trailing newline). This is what `keyRing.SSHPrivateKey.MarshalSSHPublicKey()`
//  returns in lib/client/api.go:4242.
//

import Foundation
import CryptoKit

enum HeadlessID {

    /// Compute the headless authentication ID from an SSH public key.
    ///
    /// - Parameter sshAuthorizedKey: The SSH public key in authorized_keys
    ///   format, exactly as `ssh.MarshalAuthorizedKey()` produces it
    ///   (e.g. `"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... comment\n"`).
    ///   The trailing newline is significant — it's part of the hashed bytes.
    /// - Returns: The UUID v5 string (e.g.
    ///   `"a1b2c3d4-e5f6-5a7b-8c9d-0e1f2a3b4c5d"`).
    static func compute(sshAuthorizedKey: String) -> String {
        // The namespace is uuid.Nil — 16 zero bytes.
        let namespace = Data(count: 16)
        // The name is the raw bytes of the authorized_keys string (UTF-8).
        // ssh.MarshalAuthorizedKey appends a trailing "\n"; SSHPubKey.generate
        // does NOT, so we must add it here to match the Go derivation exactly.
        let name = Data((sshAuthorizedKey + "\n").utf8)

        // SHA256(namespace || name)
        var hasher = SHA256()
        hasher.update(data: namespace)
        hasher.update(data: name)
        let digest = hasher.finalize()

        // Take the first 16 bytes.
        var bytes = Array(digest.prefix(16))

        // Set version (5) in the high nibble of byte[6].
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        // Set RFC 9562 variant in the high bits of byte[8].
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        // Format as UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        return formatUUID(bytes: bytes)
    }

    /// Format 16 bytes as a UUID string (lowercase, hyphenated).
    private static func formatUUID(bytes: [UInt8]) -> String {
        // UUID string format: 8-4-4-4-12 hex chars.
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        // Insert hyphens at positions 8, 12, 16, 20.
        var result = ""
        result.append(String(hex.prefix(8)))
        result.append("-")
        result.append(String(hex.dropFirst(8).prefix(4)))
        result.append("-")
        result.append(String(hex.dropFirst(12).prefix(4)))
        result.append("-")
        result.append(String(hex.dropFirst(16).prefix(4)))
        result.append("-")
        result.append(String(hex.dropFirst(20).prefix(12)))
        return result
    }
}
