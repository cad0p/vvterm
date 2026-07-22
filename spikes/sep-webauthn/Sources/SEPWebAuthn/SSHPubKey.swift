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
