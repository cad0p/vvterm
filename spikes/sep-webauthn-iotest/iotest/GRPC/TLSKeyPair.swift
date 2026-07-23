// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TLSKeyPair.swift
//  iotest
//
//  Session 1.10 — ephemeral EC P-256 TLS keypair generation for the
//  headless bootstrap + gRPC mTLS dial.
//
//  Phase 1 (headless login): generate an EC P-256 keypair, PEM-encode the
//  public key as PKIX (SubjectPublicKeyInfo), and send it as `tls_pub_key`
//  in the POST /webapi/headless/login body. Teleport signs it and returns
//  `tls_cert` (a PEM cert). The private key is kept for Phase 2.
//
//  Phase 2 (gRPC mTLS dial): the raw private key bytes + PEM cert are passed
//  to GRPCTLSOptions.make() to build the NWProtocolTLS.Options for the mTLS
//  connection.
//
//  Key type: EC P-256 (ECDSA), matching Teleport's default
//  `cryptosuites.UserTLS` = `ECDSAP256` (lib/cryptosuites/suites.go:245).
//  The public key is PEM-encoded as PKIX (x509.MarshalPKIXPublicKey in Go),
//  which is what `P256.Signing.PublicKey.derRepresentation` gives us.
//
//  NOTE on private key format: the private key is kept as the raw 32-byte
//  scalar (P256.Signing.PrivateKey.rawRepresentation), NOT as PKCS#8 DER.
//  SecKeyCreateWithData with kSecAttrKeyTypeECSECPrimeRandom expects the
//  raw scalar for private keys; PKCS#8 DER (derRepresentation) fails with
//  OSStatus error -50. See Apple's Security framework docs: for EC keys
//  the data format is specified by ANSI X9.63 (raw scalar for private keys).
//

import Foundation
import CryptoKit

/// An ephemeral EC P-256 TLS keypair + PEM public key.
struct TLSKeyPair {
    /// The raw 32-byte EC P-256 private key scalar (for SecKeyCreateWithData
    /// in Phase 2). This is P256.Signing.PrivateKey.rawRepresentation.
    let privateKeyRaw: Data
    /// The PEM-encoded public key (PKIX/SubjectPublicKeyInfo): "-----BEGIN PUBLIC KEY-----\n..."
    let publicKeyPEM: String

    /// The base64-encoded PEM public key body (for the `tls_pub_key` POST
    /// field, which is a Go `[]byte` that marshals as base64). The raw bytes
    /// are the UTF-8 bytes of the PEM string.
    var tlsPubKeyB64: String {
        Data(publicKeyPEM.utf8).base64EncodedString()
    }
}

enum TLSKeyPairGen {

    /// Generate a fresh EC P-256 keypair + PEM public key.
    static func generate() throws -> TLSKeyPair {
        let priv = P256.Signing.PrivateKey()
        let pub = priv.publicKey

        // Public key: PKIX DER → PEM (for the POST body).
        let pubDER = pub.derRepresentation  // SubjectPublicKeyInfo (PKIX)
        let pubPEM = pemWrap(der: pubDER, label: "PUBLIC KEY")

        // Private key: raw 32-byte scalar (for SecKeyCreateWithData in Phase 2).
        // NOT derRepresentation (PKCS#8) — SecKeyCreateWithData expects the
        // raw scalar for kSecAttrKeyTypeECSECPrimeRandom private keys.
        let privRaw = priv.rawRepresentation

        return TLSKeyPair(privateKeyRaw: privRaw, publicKeyPEM: pubPEM)
    }

    /// Wrap DER bytes in a PEM block: "-----BEGIN <label>-----\n<base64>\n-----END <label>-----\n"
    /// with 64-char lines (matching Go's pem.EncodeToMemory).
    static func pemWrap(der: Data, label: String) -> String {
        let b64 = der.base64EncodedString()
        var lines: [String] = []
        lines.append("-----BEGIN \(label)-----")
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<end]))
            idx = end
        }
        lines.append("-----END \(label)-----")
        return lines.joined(separator: "\n") + "\n"
    }
}
