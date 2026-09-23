// SPDX-License-Identifier: MIT
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
        // The wire-format walk lives in `OpenSSHCertificate` (Domain) so the
        // same parser backs the issued-cert binding check and the host
        // certificate verifier.
        if let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: pem) {
            return cert.validBeforeDate
        }
        // Fall back to X.509 PEM (the TLS cert path).
        return parseX509CertValidBefore(pem: pem)
    }

    // MARK: - X.509 PEM certificate

    /// Parse the NotAfter validity from an X.509 PEM certificate via the
    /// Security framework. Returns nil if parsing fails.
    ///
    /// NOTE: `SecCertificateCopyValues` + the `kSecPropertyOID`/`kSecPropertyKeyValue`/
    /// `kSecOIDX509V1ValidityNotAfter` constants are macOS-only and unavailable on
    /// iOS. The SSH-cert parsing path (parseSSHCertValidBefore) is the primary
    /// path and handles Teleport-issued certs; this X.509 fallback is a
    /// best-effort macOS bonus. On iOS it returns nil and the caller falls back
    /// to the 1h default.
    #if os(macOS)
    private static func parseX509CertValidBefore(pem: String) -> Date? {
        // Strip PEM headers + base64-decode the DER body.
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: true)
        let b64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return nil
        }

        // SecCertificateCopyValues returns a dictionary keyed by OID. The
        // kSecOIDX509V1ValidityNotAfter entry holds the expiry under
        // kSecPropertyKeyValue.
        guard let values = SecCertificateCopyValues(
            cert,
            [kSecOIDX509V1ValidityNotAfter] as CFArray,
            nil
        ) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let date = entry[kSecPropertyKeyValue] as? Date else {
            return nil
        }
        return date
    }
    #else
    private static func parseX509CertValidBefore(pem: String) -> Date? {
        // iOS: SecCertificateCopyValues + the kSecProperty* constants are
        // unavailable. Return nil so the caller falls back to the 1h default.
        return nil
    }
    #endif
}
