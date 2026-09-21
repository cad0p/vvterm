// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportIssuedCertValidator.swift
//  VVTerm
//
//  Post-issuance binding checks for Teleport certificates.
//
//  The WebAuthn assertion covers the challenge + origin, not the SSH / TLS
//  public keys that ride along in the same `login/finish` /
//  `headless/login` request. The headless server path binds the issued
//  certs to the request keypair (`lib/auth/methods.go`), but the passwordless
//  webapi path historically did not, so the client verifies after issuance:
//
//    - the returned SSH certificate is a USER certificate;
//    - its public key is byte-identical to the key we generated and sent;
//    - its validity window is sane for the requested TTL;
//    - it carries at least one principal.
//
//  The bootstrap additionally binds the returned `tls_cert` to the
//  generated TLS keypair. Nothing is stored when any check fails.
//

import Foundation
import Security

enum TeleportIssuedCertValidator {

    enum Failure: Error, Equatable, LocalizedError {
        /// The returned string is not an OpenSSH SSH certificate.
        case notAnSSHCertificate
        /// The certificate is a host certificate, not a user certificate.
        case notAUserCertificate
        /// The certificate's public key does not match the generated key.
        case publicKeyMismatch
        /// The certificate has no principals.
        case noPrincipals
        /// The validity window is inconsistent with the requested TTL.
        case invalidValidityWindow(String)
        /// The TLS certificate could not be parsed / its key extracted.
        case tlsCertificateUnreadable
        /// The `tls_cert` public key does not match the generated TLS key.
        case tlsPublicKeyMismatch

        var errorDescription: String? {
            switch self {
            case .notAnSSHCertificate:
                return "issued cert is not an OpenSSH SSH certificate"
            case .notAUserCertificate:
                return "issued cert is not a user certificate"
            case .publicKeyMismatch:
                return "issued cert public key does not match the requested keypair"
            case .noPrincipals:
                return "issued cert carries no principals"
            case .invalidValidityWindow(let detail):
                return "issued cert validity window is invalid (\(detail))"
            case .tlsCertificateUnreadable:
                return "issued TLS cert could not be parsed"
            case .tlsPublicKeyMismatch:
                return "issued TLS cert public key does not match the bootstrap keypair"
            }
        }
    }

    /// Validate an issued SSH user certificate against the generated key.
    ///
    /// - Parameters:
    ///   - certPEM: the issued certificate (authorized_keys line or PEM).
    ///   - expectedPublicKeyBlob: the OpenSSH key blob of the generated key
    ///     (the base64 field of its authorized_keys line, decoded).
    ///   - requestedTTL: the requested certificate lifetime in seconds.
    ///   - now: the client clock (injectable for tests).
    ///   - clockSkew: tolerance applied to the TTL upper bound (Teleport may
    ///     backdate/shorten certs; hosts clocks drift).
    static func validateIssuedUserCert(
        _ certPEM: String,
        expectedPublicKeyBlob: Data,
        requestedTTL: TimeInterval,
        now: Date,
        clockSkew: TimeInterval = 60
    ) -> Result<OpenSSHCertificate, Failure> {
        guard let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM) else {
            return .failure(.notAnSSHCertificate)
        }
        guard cert.certType == .user else {
            return .failure(.notAUserCertificate)
        }
        guard cert.publicKeyBlob == expectedPublicKeyBlob else {
            return .failure(.publicKeyMismatch)
        }
        guard !cert.validPrincipals.isEmpty else {
            return .failure(.noPrincipals)
        }

        let validAfter = cert.validAfterDate
        let validBefore = cert.validBeforeDate
        guard validAfter <= now.addingTimeInterval(clockSkew) else {
            return .failure(.invalidValidityWindow("not valid before \(validAfter)"))
        }
        guard validBefore > now else {
            return .failure(.invalidValidityWindow("already expired at \(validBefore)"))
        }
        let maxValidBefore = now.addingTimeInterval(max(requestedTTL, 0) + clockSkew)
        guard validBefore <= maxValidBefore else {
            return .failure(.invalidValidityWindow("expiry \(validBefore) exceeds requested TTL"))
        }
        return .success(cert)
    }

    /// Validate that the issued TLS certificate certifies the generated
    /// bootstrap TLS keypair (Phase-2 gRPC identity).
    ///
    /// - Parameters:
    ///   - tlsCertPEM: the PEM TLS certificate from the bootstrap response.
    ///   - expectedPrivateKey: the generated bootstrap TLS private key.
    static func validateTLSCertBinding(
        _ tlsCertPEM: String,
        expectedPrivateKey: SecKey
    ) -> Failure? {
        guard let der = try? TeleportTLSTrust.pemToDER(pem: tlsCertPEM, label: "CERTIFICATE"),
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let certificateKey = SecCertificateCopyKey(certificate),
              let certificateData = SecKeyCopyExternalRepresentation(certificateKey, nil) as Data?,
              let expectedPublicKey = SecKeyCopyPublicKey(expectedPrivateKey),
              let expectedData = SecKeyCopyExternalRepresentation(expectedPublicKey, nil) as Data? else {
            return .tlsCertificateUnreadable
        }
        return certificateData == expectedData ? nil : .tlsPublicKeyMismatch
    }
}
