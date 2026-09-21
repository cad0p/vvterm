// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportTLSTrust.swift
//  VVTerm
//
//  Server-certificate verification for the Teleport ALPN legs.
//
//  Teleport's TLS Routing (RFD 39) serves the proxy's own identity on the
//  ALPN routes. The proxy host certificate is signed by the cluster **Host
//  CA** — the same CA whose x509 certs arrive in `host_signers[0].tls_certs`
//  at bootstrap. Clients are expected to verify the server against the Host
//  CA as a trust anchor and to check the certificate against the expected
//  names; `tsh` does exactly this after login (`configureTLS` with the
//  cluster CA as roots).
//
//  What matters for the ALPN legs:
//    - The expected names are the dial host and `teleport.cluster.local`
//      for the SSH leg (`teleport-proxy-ssh`); the encoded auth route name
//      (`<hex(cluster)>.teleport.cluster.local`) and `teleport.cluster.local`
//      for the gRPC auth leg (`teleport-auth@<hex>`).
//    - The negotiated ALPN must be the protocol we asked for; an HTTP edge
//      that terminates TLS and negotiates `h2` must not be accepted.
//
//  This file is the single place that turns the incoming `SecTrust` into an
//  accept/reject decision. It never evaluates the trust's inherited policy
//  (Network.framework does not document the policy it attaches to the trust,
//  so a BasicX509 policy could accept any Host-CA chain); it sets an explicit
//  SSL policy per candidate name instead.
//

#if canImport(Network)
import Foundation
import Network
import Security
import Darwin
import os.log

enum TeleportTLSTrust {

    /// The cluster-independent TLS SAN every Teleport proxy host certificate
    /// carries (mirrors `DefaultDNSNamesForRole` in Teleport's `lib/auth`).
    static let clusterLocalName = "teleport.cluster.local"

    /// Parse PEM-encoded certificates into `SecCertificate` anchors.
    ///
    /// Malformed entries are skipped (a bad PEM must not crash the transport
    /// constructor), but callers must fail closed when the input was
    /// non-empty and the result is empty — see `SSHTLSTransport` /
    /// `GRPCTLSOptions`, which throw in that case. Duplicate certificates are
    /// collapsed so the same CA served twice does not matter.
    static func anchors(fromPEMs pems: [String]) -> [SecCertificate] {
        var certificates: [SecCertificate] = []
        var seenDER = Set<Data>()
        for pem in pems {
            guard let der = try? pemToDER(pem: pem, label: "CERTIFICATE"),
                  !seenDER.contains(der),
                  let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                continue
            }
            seenDER.insert(der)
            certificates.append(certificate)
        }
        return certificates
    }

    /// Strip PEM headers and base64-decode the DER body.
    static func pemToDER(pem: String, label: String) throws -> Data {
        let lines = pem.split(separator: "\n", omittingEmptySubsequences: true)
        let b64 = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: b64) else {
            throw TeleportTLSTrustError.malformedPEM(label)
        }
        return data
    }

    /// The expected server names for the SSH ALPN leg (`teleport-proxy-ssh`).
    static func sshServerNames(dialHost: String) -> [String] {
        [dialHost, clusterLocalName]
    }

    /// The expected server names for the gRPC auth ALPN leg
    /// (`teleport-auth@<hex(cluster)>`). The APIDomain form mirrors `tsh`;
    /// public proxy addresses become SSH principals, not TLS SANs.
    static func authServerNames(clusterName: String) -> [String] {
        [encodedClusterName(clusterName), clusterLocalName]
    }

    /// Encode a cluster name the way Teleport does: hex(name) +
    /// ".teleport.cluster.local". See `api/utils/cluster.go:EncodeClusterName`.
    static func encodedClusterName(_ name: String) -> String {
        let hex = name.utf8.map { String(format: "%02x", $0) }.joined()
        return "\(hex).\(clusterLocalName)"
    }

    /// Decide whether the presented trust is acceptable.
    ///
    /// Every `OSStatus` is checked; any non-`errSecSuccess` result is a
    /// failure. The negotiated ALPN must equal `requiredALPN`. The trust's
    /// inherited policy is replaced with an explicit SSL policy per candidate
    /// name (certificate hostname verification happens inside
    /// `SecTrustEvaluateWithError`); passing any candidate name accepts.
    ///
    /// - Returns: `ok` plus the last evaluation error (or an explanatory
    ///   error for a policy/ALPN failure).
    static func verify(
        trust: SecTrust,
        anchors: [SecCertificate],
        serverNames: [String],
        negotiatedALPN: String?,
        requiredALPN: String
    ) -> (ok: Bool, error: CFError?) {
        guard negotiatedALPN == requiredALPN else {
            return failure(
                "ALPN mismatch: negotiated \(negotiatedALPN ?? "nil"), required \(requiredALPN)"
            )
        }

        guard !anchors.isEmpty else {
            return failure("no trust anchors supplied")
        }

        let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        guard anchorStatus == errSecSuccess else {
            return failure("SecTrustSetAnchorCertificates failed (OSStatus \(anchorStatus))")
        }
        let anchorOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard anchorOnlyStatus == errSecSuccess else {
            return failure("SecTrustSetAnchorCertificatesOnly failed (OSStatus \(anchorOnlyStatus))")
        }

        var lastError: CFError?
        for name in serverNames {
            let policy = SecPolicyCreateSSL(true, name as CFString)
            let policyStatus = SecTrustSetPolicies(trust, [policy] as CFArray)
            guard policyStatus == errSecSuccess else {
                return failure("SecTrustSetPolicies failed for a candidate name (OSStatus \(policyStatus))")
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                return (true, nil)
            }
            lastError = error
            // Teleport host certificates are long-lived by design, and Apple's
            // SSL policy enforces the 398-day public-CA maximum validity even
            // when the chain is anchored to a pinned private CA. Re-evaluate
            // with BasicX509 + an explicit SAN match only for that specific
            // failure: the chain, validity window, signatures, and anchor set
            // are still enforced, and the hostname is still checked.
            if isCertificateValidityPeriodTooLong(error),
               evaluateBasicChainAndName(trust: trust, name: name) {
                return (true, nil)
            }
        }
        if let lastError {
            return (false, lastError)
        }
        return failure("no server name candidates")
    }

    /// True when `SecTrustEvaluateWithError` rejected the leaf only because its
    /// validity window exceeds the public-CA maximum (398 days).
    private static func isCertificateValidityPeriodTooLong(_ error: CFError?) -> Bool {
        guard let error else { return false }
        return CFErrorGetDomain(error) as String == kCFErrorDomainOSStatus as String
            && CFErrorGetCode(error) == errSecCertificateValidityPeriodTooLong
    }

    /// Fallback used for long-lived Host-CA host certificates: evaluate the
    /// chain with a BasicX509 policy against the same pinned anchors, then
    /// match the candidate name against the leaf's subjectAltName entries.
    private static func evaluateBasicChainAndName(trust: SecTrust, name: String) -> Bool {
        let basicPolicy = SecPolicyCreateBasicX509()
        guard SecTrustSetPolicies(trust, [basicPolicy] as CFArray) == errSecSuccess else {
            return false
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        return certificate(leaf, matchesName: name)
    }

    /// Whether the certificate's subjectAltName covers `name`.
    ///
    /// Supports exact DNS names, single-label wildcards (`*.example.com`
    /// matches `a.example.com`, not `example.com` or `a.b.example.com`), and
    /// IP-address SANs (compared as parsed bytes). The SAN extension is read
    /// from the DER directly: `SecCertificateCopyValues` is macOS-only, and
    /// the match must behave identically on iOS.
    static func certificate(_ certificate: SecCertificate, matchesName name: String) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              let entries = subjectAltNameEntries(certificate) else {
            return false
        }
        if entries.dnsNames.contains(where: { dnsName($0, matches: candidate) }) {
            return true
        }
        if let candidateBytes = ipBytes(candidate),
           entries.ipAddresses.contains(candidateBytes) {
            return true
        }
        return false
    }

    private static func dnsName(_ pattern: String, matches candidate: String) -> Bool {
        let pattern = pattern.lowercased()
        let candidate = candidate.lowercased()
        if pattern == candidate { return true }
        guard pattern.hasPrefix("*.") else { return false }
        let suffix = String(pattern.dropFirst(2))
        guard candidate.hasSuffix("." + suffix) else { return false }
        let prefix = candidate.dropLast(suffix.count + 1)
        return !prefix.isEmpty && !prefix.contains(".")
    }

    private static func ipBytes(_ candidate: String) -> Data? {
        for family in [AF_INET, AF_INET6] {
            let byteCount = family == AF_INET6 ? 16 : 4
            var bytes = [UInt8](repeating: 0, count: byteCount)
            if candidate.withCString({ inet_pton(family, $0, &bytes) }) == 1 {
                return Data(bytes)
            }
        }
        return nil
    }

    /// Extract the subjectAltName DNS names and IP addresses from the leaf's
    /// DER encoding (`TBSCertificate.extensions[3]` → `2.5.29.17`).
    ///
    /// A minimal DER walker is used because `SecCertificateCopyValues` is not
    /// available on iOS. Malformed input returns nil (fail closed).
    private static func subjectAltNameEntries(
        _ certificate: SecCertificate
    ) -> (dnsNames: [String], ipAddresses: [Data])? {
        let der = SecCertificateCopyData(certificate) as Data

        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        var certificateCursor = DERCursor(der)
        guard let certificateSequence = certificateCursor.next(), certificateSequence.tag == 0x30 else {
            return nil
        }

        // TBSCertificate ::= SEQUENCE { version [0] EXPLICIT OPTIONAL, serialNumber,
        //   signature, issuer, validity, subject, subjectPublicKeyInfo,
        //   issuerUniqueID [1] OPTIONAL, subjectUniqueID [2] OPTIONAL,
        //   extensions [3] EXPLICIT OPTIONAL }
        var tbsCursor = DERCursor(certificateSequence.content)
        guard let tbsCertificate = tbsCursor.next(), tbsCertificate.tag == 0x30 else {
            return nil
        }
        var tbsFields = DERCursor(tbsCertificate.content)
        var extensionsField: [UInt8]?
        while let field = tbsFields.next() {
            if field.tag == 0xA3 {
                extensionsField = field.content
                break
            }
        }
        guard let extensionsField else { return nil }

        // Extensions ::= SEQUENCE OF Extension
        // Extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
        var extensionsCursor = DERCursor(extensionsField)
        guard let extensionsSequence = extensionsCursor.next(), extensionsSequence.tag == 0x30 else {
            return nil
        }
        var extensionCursor = DERCursor(extensionsSequence.content)
        while let extensionElement = extensionCursor.next() {
            guard extensionElement.tag == 0x30 else { continue }
            var fields = DERCursor(extensionElement.content)
            guard let oid = fields.next(), oid.tag == 0x06 else { continue }
            // 2.5.29.17 subjectAltName
            guard oid.content == [0x55, 0x1D, 0x11] else { continue }
            var valueElement = fields.next()
            if valueElement?.tag == 0x01 {
                valueElement = fields.next()
            }
            guard let extnValue = valueElement, extnValue.tag == 0x04 else { return nil }

            // GeneralNames ::= SEQUENCE OF GeneralName; [2] dNSName, [7] iPAddress
            var generalNamesCursor = DERCursor(extnValue.content)
            guard let generalNames = generalNamesCursor.next(), generalNames.tag == 0x30 else {
                return nil
            }
            var namesCursor = DERCursor(generalNames.content)
            var dnsNames: [String] = []
            var ipAddresses: [Data] = []
            while let name = namesCursor.next() {
                switch name.tag {
                case 0x82:
                    if let string = String(bytes: name.content, encoding: .utf8) {
                        dnsNames.append(string)
                    }
                case 0x87:
                    ipAddresses.append(Data(name.content))
                default:
                    continue
                }
            }
            return (dnsNames, ipAddresses)
        }
        return nil
    }

    /// Minimal definite-length DER reader for the SAN walk above.
    private struct DERCursor {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) { bytes = [UInt8](data) }
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> (tag: UInt8, content: [UInt8])? {
            guard offset < bytes.count else { return nil }
            let tag = bytes[offset]
            offset += 1
            guard let length = readLength(), offset + length <= bytes.count else { return nil }
            let content = Array(bytes[offset..<(offset + length)])
            offset += length
            return (tag, content)
        }

        private mutating func readLength() -> Int? {
            guard offset < bytes.count else { return nil }
            let first = bytes[offset]
            offset += 1
            if first < 0x80 { return Int(first) }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 3, offset + byteCount <= bytes.count else {
                return nil
            }
            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
            return length
        }
    }

    /// Build the `sec_protocol_verify_t` block used by both ALPN transports.
    ///
    /// The block reads the negotiated ALPN from the protocol metadata (the
    /// SDK offers no metadata factory, so metadata extraction itself stays
    /// untested; the decision logic is exercised directly through `verify`).
    static func makeVerifyBlock(
        anchors: [SecCertificate],
        serverNames: [String],
        requiredALPN: String,
        logger: Logger
    ) -> sec_protocol_verify_t {
        { metadata, secTrust, complete in
            let negotiatedALPN = negotiatedProtocol(from: metadata)
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            let result = verify(
                trust: trust,
                anchors: anchors,
                serverNames: serverNames,
                negotiatedALPN: negotiatedALPN,
                requiredALPN: requiredALPN
            )
            if !result.ok {
                let nameList = serverNames.joined(separator: ",")
                let errorDescription = result.error.map { String(describing: $0) } ?? "unknown"
                logger.error(
                    "teleport_tls_verify_failed server_names=\(nameList, privacy: .private(mask: .hash)) alpn=\(negotiatedALPN ?? "nil", privacy: .public) error=\(errorDescription, privacy: .private(mask: .hash))"
                )
            }
            complete(result.ok)
        }
    }

    /// The negotiated application protocol (ALPN) from protocol metadata.
    ///
    /// `sec_protocol_metadata_copy_negotiated_protocol` (macOS 15.5+, iOS
    /// 18.5+) returns a caller-owned C string that must be freed; the older
    /// `sec_protocol_metadata_get_negotiated_protocol` returns a
    /// non-owned pointer that must NOT be freed.
    static func negotiatedProtocol(from metadata: sec_protocol_metadata_t) -> String? {
        if #available(macOS 15.5, iOS 18.5, *) {
            guard let cString = sec_protocol_metadata_copy_negotiated_protocol(metadata) else {
                return nil
            }
            defer { free(UnsafeMutableRawPointer(mutating: cString)) }
            return String(cString: cString)
        } else {
            guard let cString = sec_protocol_metadata_get_negotiated_protocol(metadata) else {
                return nil
            }
            return String(cString: cString)
        }
    }

    // MARK: - Errors

    private static func failure(_ message: String) -> (ok: Bool, error: CFError?) {
        let error = CFErrorCreate(
            nil,
            "VVTerm.TeleportTLSTrust" as CFErrorDomain,
            1,
            [kCFErrorLocalizedDescriptionKey: message] as CFDictionary
        )
        return (false, error)
    }
}

/// Errors thrown by the shared PEM helpers.
enum TeleportTLSTrustError: LocalizedError {
    case malformedPEM(String)

    var errorDescription: String? {
        switch self {
        case .malformedPEM(let label):
            return "Failed to decode PEM (\(label))"
        }
    }
}

#endif // canImport(Network)
