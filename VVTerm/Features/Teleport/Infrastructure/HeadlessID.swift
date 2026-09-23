// SPDX-License-Identifier: MIT
//
//  HeadlessID.swift
//  VVTerm
//
//  Derives the headless authentication ID for the Phase-1 bootstrap.
//
//  The ID identifies one pending headless login on both the blocking
//  `POST /webapi/headless/login` call and the `/web/headless/<id>` approval
//  page, so the server and the app must derive the same value from the same
//  SSH public key.
//
//  The derivation is a UUIDv5-style name hash (RFC 9562 §5.5 layout) with
//  SHA-256 instead of the RFC's SHA-1 default and an all-zero 16-byte
//  namespace — the same construction the server's `uuid.NewHash` call uses.
//  It is not a random ID: two runs with the same key produce the same UUID,
//  which is what lets the approval page and the blocking POST meet.
//

import Foundation
import CryptoKit

enum HeadlessID {

    /// Computes the headless authentication ID for an SSH public key.
    ///
    /// `sshAuthorizedKey` is a single authorized_keys line **without** a
    /// trailing newline (the bootstrap coordinator builds it from the freshly
    /// generated ed25519 key). Exactly one `\n` is appended before hashing,
    /// matching the server's `ssh.MarshalAuthorizedKey` input shape. The
    /// input is not normalized: a caller that already appends a newline gets
    /// that second newline hashed too, and therefore a different ID.
    ///
    /// - Parameter sshAuthorizedKey: the authorized_keys line to derive from.
    /// - Returns: a lowercase hyphenated UUID string (8-4-4-4-12).
    static func compute(sshAuthorizedKey: String) -> String {
        // Namespace: 16 zero bytes (uuid.Nil). Name: the authorized_keys
        // line plus exactly one newline.
        var hashedBytes = Data(repeating: 0, count: 16)
        hashedBytes.append(Data((sshAuthorizedKey + "\n").utf8))

        let digest = SHA256.hash(data: hashedBytes)
        var uuidBytes = Array(digest.prefix(16))

        // Stamp the version (5 = name-based, SHA-256 variant) into the high
        // nibble of byte 6 and the RFC 9562 variant (10xx) into the high bits
        // of byte 8.
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

        return hyphenated(uuidBytes)
    }

    /// Formats 16 bytes as a lowercase 8-4-4-4-12 UUID string.
    private static func hyphenated(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }
        let groups = [
            hex[0..<4].joined(),
            hex[4..<6].joined(),
            hex[6..<8].joined(),
            hex[8..<10].joined(),
            hex[10..<16].joined(),
        ]
        return groups.joined(separator: "-")
    }
}
