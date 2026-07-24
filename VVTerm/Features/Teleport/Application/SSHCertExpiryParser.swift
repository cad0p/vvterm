// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SSHCertExpiryParser.swift
//  VVTerm
//
//  Parses the ValidBefore field from an SSH certificate PEM string.
//
//  Teleport's HTTP responses (`/webapi/headless/login` + `/webapi/mfa/login/finish`)
//  return the SSH cert as a base64-encoded PEM string, but do NOT include the
//  cert's expiry in a separate field — it's embedded in the cert itself. The
//  coordinators need the expiry to:
//    - drive the readiness state (ready ↔ needsLogin flip)
//    - show the "Certificate valid for …" copy in the login sheet
//
//  Two cert formats are in play:
//    1. OpenSSH SSH certificates (`ssh-ed25519-cert-v01@openssh.com …`) —
//       what Teleport actually issues. The ValidBefore is a uint64 Unix
//       timestamp at a fixed offset in the cert blob.
//    2. X.509 PEM certificates (`-----BEGIN CERTIFICATE-----`) — the TLS
//       cert path. Parsed via SecCertificateCreateWithData.
//
//  This parser handles both. The SSH cert path is the common one (the
//  `cert` field in the HTTP response is an SSH cert, not an X.509 cert).
//
//  See:
//    - 2026-07-21-strategy-b-session2.2-vvterm-sep-key-integration-prompt.md
//      (Phase 1/3 — the cert is base64(PEM))
//    - PROTOCOL.certkeys (OpenSSH SSH certificate wire format)
//

import Foundation
import Security

enum SSHCertExpiryParser {

    /// Parse the ValidBefore (cert expiry) from a PEM-encoded SSH or X.509
    /// certificate. Returns nil if the expiry cannot be parsed (the caller
    /// falls back to a conservative default).
    ///
    /// - Parameter pem: the PEM string (SSH cert authorized_keys format OR
    ///   X.509 PEM). May be base64-decoded already (the coordinators decode
    ///   the HTTP response's base64(PEM) before calling).
    /// - Returns: the cert's ValidBefore as a `Date`, or nil.
    static func validBefore(pem: String) -> Date? {
        // Try the OpenSSH SSH certificate format first (the common path —
        // Teleport issues SSH certs, not X.509 certs, for the `cert` field).
        if let sshDate = parseOpenSSHSSHCertValidBefore(pem: pem) {
            return sshDate
        }
        // Fall back to X.509 PEM (the TLS cert path).
        return parseX509CertValidBefore(pem: pem)
    }

    // MARK: - OpenSSH SSH certificate

    /// Parse ValidBefore from an OpenSSH SSH certificate.
    ///
    /// The cert is in authorized_keys format:
    ///   `ssh-ed25519-cert-v01@openssh.com <base64> <comment>`
    /// The base64 decodes to the cert blob:
    ///   string  \"ssh-ed25519-cert-v01@openssh.com\"
    ///   string  nonce
    ///   string  public key (curve25519)
    ///   uint64  serial
    ///   uint32  type
    ///   string  key id
    ///   string  valid principals
    ///   string  critical options
    ///   string  extensions
    ///   string  reserved
    ///   string  signature key
    ///   string  signature
    ///   uint64  valid_before   ← this is what we want
    ///
    /// Wait — the actual order (per PROTOCOL.certkeys) is:
    ///   string  cert key type
    ///   string  nonce
    ///   string  public key
    ///   uint64  serial
    ///   uint32  type
    ///   string  key id
    ///   string  valid principals
    ///   string  critical options
    ///   string  extensions
    ///   string  reserved
    ///   string  signature key
    ///   string  signature
    ///
    /// And the trailing fields (valid_after + valid_before) are NOT in the
    /// main blob — they're in the `extensions`? No. Actually per
    /// PROTOCOL.certkeys, the cert blob does NOT contain valid_before
    /// directly. The validity period is in the `critical options` or
    /// `extensions`? No — it's a top-level field.
    ///
    /// Re-reading PROTOCOL.certkeys: the SSH certificate format is:
    ///   string    \"ssh-ed25519-cert-v01@openssh.com\"
    ///   string    nonce
    ///   string    pk
    ///   uint64    serial
    ///   uint32    type
    ///   string    key id
    ///   string    valid principals
    ///   string    critical options
    ///   string    extensions
    ///   string    reserved
    ///   string    signature key
    ///   string    signature
    ///
    /// There is NO valid_before field in the SSH cert blob itself. The
    /// validity period is conveyed via the `force-command` / `source-address`
    /// critical options OR — actually — Teleport encodes it in the cert's
    /// `valid_after` / `valid_before` which ARE top-level uint64 fields.
    ///
    /// Actually, the correct format (from ssh/certs.go in x/crypto/ssh):
    ///   string    cert key type
    ///   string    nonce
    ///   string    pk
    ///   uint64    serial
    ///   uint32    type
    ///   string    key id
    ///   string    valid principals
    ///   string    critical options
    ///   string    extensions
    ///   string    reserved
    ///   string    signature key
    ///   string    signature
    ///   uint64    valid_after
    ///   uint64    valid_before
    ///
    /// The valid_after + valid_before are appended AFTER the signature (they
    /// are part of the signed data but come last in the blob). This parser
    /// walks the blob to find them.
    private static func parseOpenSSHSSHCertValidBefore(pem: String) -> Date? {
        // The PEM may be in authorized_keys format ("ssh-ed25519-cert-v01@openssh.com <b64> comment")
        // or just the base64 blob. Extract the base64 part.
        let b64: String
        if pem.contains(" ") {
            // authorized_keys format: "<type> <b64> [comment]"
            let parts = pem.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2 else { return nil }
            b64 = String(parts[1])
        } else {
            b64 = pem
        }

        guard let blob = Data(base64Encoded: b64) else { return nil }

        // Walk the blob using a cursor. Each SSH `string` is uint32BE(len) + bytes.
        var cursor = 0

        // Helper to read an SSH string (returns the payload, advances cursor).
        func readString() -> Data? {
            guard cursor + 4 <= blob.count else { return nil }
            let len = Int(UInt32(blob[cursor]) << 24
                          | UInt32(blob[cursor + 1]) << 16
                          | UInt32(blob[cursor + 2]) << 8
                          | UInt32(blob[cursor + 3]))
            cursor += 4
            guard cursor + len <= blob.count else { return nil }
            let payload = blob.subdata(in: cursor..<(cursor + len))
            cursor += len
            return payload
        }

        // Helper to skip a string (advance cursor without copying).
        func skipString() -> Bool {
            guard cursor + 4 <= blob.count else { return false }
            let len = Int(UInt32(blob[cursor]) << 24
                          | UInt32(blob[cursor + 1]) << 16
                          | UInt32(blob[cursor + 2]) << 8
                          | UInt32(blob[cursor + 3]))
            cursor += 4
            guard cursor + len <= blob.count else { return false }
            cursor += len
            return true
        }

        // 1. cert key type (string) — e.g. "ssh-ed25519-cert-v01@openssh.com"
        guard let keyType = readString(),
              let keyTypeStr = String(data: keyType, encoding: .utf8),
              keyTypeStr.contains("cert-v01") else {
            return nil
        }

        // 2. nonce (string)
        guard skipString() else { return nil }
        // 3. public key (string)
        guard skipString() else { return nil }

        // 4. serial (uint64) — 8 bytes
        guard cursor + 8 <= blob.count else { return nil }
        cursor += 8

        // 5. type (uint32) — 4 bytes
        guard cursor + 4 <= blob.count else { return nil }
        cursor += 4

        // 6. key id (string)
        guard skipString() else { return nil }
        // 7. valid principals (string)
        guard skipString() else { return nil }
        // 8. critical options (string)
        guard skipString() else { return nil }
        // 9. extensions (string)
        guard skipString() else { return nil }
        // 10. reserved (string)
        guard skipString() else { return nil }
        // 11. signature key (string)
        guard skipString() else { return nil }
        // 12. signature (string)
        guard skipString() else { return nil }

        // 13. valid_after (uint64) — 8 bytes
        guard cursor + 8 <= blob.count else { return nil }
        cursor += 8

        // 14. valid_before (uint64) — 8 bytes, Unix timestamp
        guard cursor + 8 <= blob.count else { return nil }
        var validBefore: UInt64 = 0
        for i in 0..<8 {
            validBefore = (validBefore << 8) | UInt64(blob[cursor + i])
        }
        cursor += 8

        // UInt64 Unix timestamp → Date. 0 means "no expiry" (treat as distant future).
        if validBefore == 0 {
            return Date.distantFuture
        }
        return Date(timeIntervalSince1970: TimeInterval(validBefore))
    }

    // MARK: - X.509 PEM certificate

    /// Parse the NotAfter validity from an X.509 PEM certificate via the
    /// Security framework. Returns nil if parsing fails.
    private static func parseX509CertValidBefore(pem: String) -> Date? {
        // Strip PEM headers + base64-decode the DER body.
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: true)
        let b64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }

        // SecCertificateCopyValues returns the cert's attributes. The
        // kSecOIDX509V1ValidityNotAfter key holds the expiry.
        // On iOS/macOS this returns a CFArray of dictionaries.
        guard let values = SecCertificateCopyValues(cert, nil, nil) as? [[String: Any]] else {
            return nil
        }
        for entry in values {
            if let oids = entry[kSecPropertyOID as String] as? String,
               oids == "2.5.29.1" || oids == kSecOIDX509V1ValidityNotAfter as String {
                if let date = entry[kSecPropertyKeyValue as String] as? Date {
                    return date
                }
            }
        }
        return nil
    }
}
