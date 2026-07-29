// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TLSKeyPair.swift
//  VVTerm
//
//  Ephemeral EC P-256 TLS keypair generation for the headless bootstrap +
//  gRPC mTLS dial.
//
//  Phase 1 (headless login): generate an EC P-256 keypair, PEM-encode the
//  public key as PKIX (SubjectPublicKeyInfo), and send it as `tls_pub_key`
//  in the POST /webapi/headless/login body. Teleport signs it and returns
//  `tls_cert` (a PEM cert). The private key is kept for Phase 2.
//
//  Phase 2 (gRPC mTLS dial): the SecKey + PEM cert are passed to
//  GRPCTLSOptions.make() to build the NWProtocolTLS.Options for the mTLS
//  connection.
//
//  Key type: EC P-256 (ECDSA), matching Teleport's default
//  `cryptosuites.UserTLS` = `ECDSAP256` (lib/cryptosuites/suites.go:245).
//  The public key is PEM-encoded as PKIX (x509.MarshalPKIXPublicKey in Go),
//  which is what SecKeyCopyExternalRepresentation gives us (X9.63 → wrap in
//  SubjectPublicKeyInfo... actually we use CryptoKit's derRepresentation).
//
//  NOTE on SecKey: we generate the key via SecKeyCreateRandomKey (not
//  CryptoKit) so we have a native SecKey for Phase 2's
//  sec_protocol_options_set_local_identity. SecKeyCreateWithData is finicky
//  about EC private key formats (raw scalar vs X9.63 vs PKCS#8 all fail with
//  OSStatus -50 on iOS); generating with SecKeyCreateRandomKey sidesteps the
//  format ambiguity entirely.
//

import Foundation
import CryptoKit
import Security

/// An ephemeral EC P-256 TLS keypair.
struct TLSKeyPair {
    /// The SecKey for the private key (for Phase 2's sec_identity_t).
    /// Created via SecKeyCreateRandomKey — stays valid for the process.
    let privateKey: SecKey
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

    /// Generate a fresh EC P-256 keypair via SecKeyCreateRandomKey.
    ///
    /// Uses the system Security framework (not CryptoKit) so the resulting
    /// SecKey can be passed directly to sec_protocol_options_set_local_identity
    /// without any format conversion.
    static func generate() throws -> TLSKeyPair {
        // Software EC P-256 key (not SEP — the TLS key is a transport key,
        // not a biometric-gated credential).
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let msg = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GRPCError.tls("SecKeyCreateRandomKey failed: \(msg)")
        }

        // Extract the public key in X9.63 form (0x04 || X || Y, 65 bytes).
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw GRPCError.tls("SecKeyCopyPublicKey failed")
        }
        var repError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &repError) as Data? else {
            let msg = (repError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GRPCError.tls("SecKeyCopyExternalRepresentation failed: \(msg)")
        }

        // Convert X9.63 (0x04 || X || Y) → PKIX DER (SubjectPublicKeyInfo)
        // using CryptoKit, then PEM-wrap. CryptoKit's P256.KeyAgreement.PublicKey
        // can parse X9.63 and emit DER (PKIX).
        let pubKey = try P256.KeyAgreement.PublicKey(x963Representation: publicKeyData)
        let pubDER = pubKey.derRepresentation  // SubjectPublicKeyInfo (PKIX)
        let pubPEM = pemWrap(der: pubDER, label: "PUBLIC KEY")

        return TLSKeyPair(privateKey: privateKey, publicKeyPEM: pubPEM)
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
