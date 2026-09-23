// SPDX-License-Identifier: MIT
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
//    - The negotiated ALPN, when the server picks one, must be one of the
//      protocols the leg offered; an HTTP edge that terminates TLS and
//      negotiates `h2` on the SSH leg must not be accepted. Teleport serves
//      the SSH route's host certificate without a `NextProtos` list before
//      v17, so that leg legitimately negotiates no ALPN; the auth route
//      instead negotiates `h2` after the ALPN-SNI hop (tsh offers the route
//      plus `h2`). The security gate is the Host-CA chain + name, not the
//      ALPN.
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
    /// failure. When the server negotiated an ALPN it must be one of
    /// `allowedALPNs`; `nil` is accepted because Teleport serves the SSH
    /// route without a `NextProtos` list before v17 and the auth hop
    /// negotiates its own protocol. The trust's inherited policy is replaced
    /// with an explicit SSL policy per candidate name (certificate hostname
    /// verification happens inside `SecTrustEvaluateWithError`); passing any
    /// candidate name accepts.
    ///
    /// - Returns: `ok` plus the last evaluation error (or an explanatory
    ///   error for a policy/ALPN failure).
    static func verify(
        trust: SecTrust,
        anchors: [SecCertificate],
        serverNames: [String],
        negotiatedALPN: String?,
        allowedALPNs: [String]
    ) -> (ok: Bool, error: CFError?) {
        if let negotiatedALPN, !allowedALPNs.contains(negotiatedALPN) {
            return failure(
                "ALPN mismatch: negotiated \(negotiatedALPN), allowed \(allowedALPNs.joined(separator: ","))"
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
        var rejectedCALeaf = false
        var rejectedEKU = false
        var missingLeaf = false
        for name in serverNames {
            let policy = SecPolicyCreateSSL(true, name as CFString)
            let policyStatus = SecTrustSetPolicies(trust, [policy] as CFArray)
            guard policyStatus == errSecSuccess else {
                return failure("SecTrustSetPolicies failed for a candidate name (OSStatus \(policyStatus))")
            }
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) {
                // A CA certificate must not act as the TLS server leaf even
                // when the SSL policy accepts the chain: its keyCertSign role
                // is not a server role. Enforced on the primary path as well
                // as the long-lived-cert fallback below.
                guard let leaf = leafCertificate(of: trust) else {
                    // The evaluation passed but the trust carries no leaf to
                    // inspect; fail closed with its own diagnostic instead of
                    // reporting it as a CA certificate.
                    missingLeaf = true
                    continue
                }
                if !certificateIsCA(leaf) {
                    // A Host-CA-signed leaf that is not permitted to act as a
                    // TLS server (clientAuth-only EKU, keyEncipherment-only
                    // keyUsage) must not pass just because the SSL policy's
                    // chain/name checks do. The long-lived fallback below
                    // enforces the same check; this keeps the primary path
                    // and the fallback equivalent.
                    guard certificateAllowsTLSServerUse(leaf) else {
                        rejectedEKU = true
                        continue
                    }
                    return (true, nil)
                }
                rejectedCALeaf = true
                continue
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
        if missingLeaf {
            return failure("evaluated trust has no leaf certificate")
        }
        if rejectedCALeaf {
            return failure("leaf certificate is a CA certificate")
        }
        if rejectedEKU {
            return failure("leaf certificate is not permitted for TLS server use (EKU/keyUsage)")
        }
        if let lastError {
            return (false, lastError)
        }
        return failure("no server name candidates")
    }

    /// The leaf certificate of an evaluated trust.
    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
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
    ///
    /// BasicX509 enforces the chain, signatures, and validity window but NOT
    /// the leaf's extended key usage or key usage, so both are enforced here:
    /// a Host-CA-signed leaf that is not permitted to act as a TLS server
    /// (e.g. clientAuth-only) must not be accepted just because it is
    /// long-lived.
    private static func evaluateBasicChainAndName(trust: SecTrust, name: String) -> Bool {
        let basicPolicy = SecPolicyCreateBasicX509()
        guard SecTrustSetPolicies(trust, [basicPolicy] as CFArray) == errSecSuccess else {
            return false
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { return false }
        guard let leaf = leafCertificate(of: trust) else { return false }
        guard certificate(leaf, matchesName: name) else { return false }
        guard certificateAllowsTLSServerUse(leaf) else { return false }
        // A CA certificate must not act as the TLS server leaf: its keyCertSign
        // role is not a server role, even when it carries a matching SAN and
        // serverAuth EKU. `parseExtensions` fails closed on malformed
        // basicConstraints.
        guard !certificateIsCA(leaf) else { return false }
        return true
    }

    /// Whether the certificate's basicConstraints mark it as a CA
    /// (`cA:TRUE`). Absent extension means non-CA; a malformed certificate
    /// fails closed.
    static func certificateIsCA(_ certificate: SecCertificate) -> Bool {
        guard let extensions = parseExtensions(certificate) else { return true }
        return extensions.basicConstraintsIsCA == true
    }

    /// Whether the leaf's key purpose and key usage permit a TLS server role.
    ///
    /// Extended key usage: when the extension is present it must contain
    /// `id-kp-serverAuth` (1.3.6.1.5.5.7.3.1); an absent EKU is treated as
    /// unrestricted (the same rule the platform's SSL policy applies).
    /// Key usage: when the extension is present it must include
    /// `digitalSignature` (bit 0), the only usage a TLS 1.2/1.3 server
    /// handshake requires. Malformed extensions fail closed.
    static func certificateAllowsTLSServerUse(_ certificate: SecCertificate) -> Bool {
        guard let extensions = parseExtensions(certificate) else { return false }
        if extensions.hasExtendedKeyUsage {
            let serverAuthOID: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
            guard extensions.extendedKeyUsageOIDs.contains(serverAuthOID) else { return false }
        }
        if let keyUsageBits = extensions.keyUsageBits {
            // digitalSignature is bit 0 of the keyUsage BIT STRING (the first
            // bit of the first payload byte, most significant bit first).
            guard let firstByte = keyUsageBits.first, (firstByte & 0x80) != 0 else {
                return false
            }
        }
        return true
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

    /// The leaf extensions the TLS verifier reads.
    struct ParsedExtensions {
        var dnsNames: [String] = []
        var ipAddresses: [Data] = []
        /// True when an extendedKeyUsage (2.5.29.37) extension is present.
        var hasExtendedKeyUsage = false
        /// The EKU KeyPurposeId OIDs (DER content, without tag/length).
        var extendedKeyUsageOIDs: [[UInt8]] = []
        /// The keyUsage (2.5.29.15) BIT STRING payload after the unused-bits
        /// byte, or nil when the extension is absent.
        var keyUsageBits: [UInt8]?
        /// The basicConstraints (2.5.29.19) `cA` flag when the extension is
        /// present; nil when absent (a leaf).
        var basicConstraintsIsCA: Bool?
        /// Recognized extension OIDs seen so far. RFC 5280 §4.2: a
        /// certificate MUST NOT include more than one instance of an
        /// extension, so a duplicate is malformed DER and fails closed.
        var recognizedExtensionOIDs: Set<[UInt8]> = []
    }

    /// Extract the leaf extensions the verifier needs (subjectAltName,
    /// extendedKeyUsage, keyUsage) from the DER encoding
    /// (`TBSCertificate.extensions[3]`).
    ///
    /// A minimal DER walker is used because `SecCertificateCopyValues` is not
    /// available on iOS. Malformed input returns nil (fail closed).
    private static func parseExtensions(_ certificate: SecCertificate) -> ParsedExtensions? {
        parseExtensions(der: SecCertificateCopyData(certificate) as Data)
    }

    /// DER-only entry point for the extension walk (directly testable with
    /// synthetic certificate encodings).
    static func parseExtensions(der: Data) -> ParsedExtensions? {
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        var certificateCursor = DERCursor(der)
        guard let certificateSequence = certificateCursor.next(), certificateSequence.tag == 0x30 else {
            return nil
        }
        // Trailing bytes after the outer Certificate SEQUENCE would be
        // ignored by this walker while another parser could read them, so
        // fail closed.
        guard certificateCursor.isAtEnd else { return nil }

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
        // Extensions are the final TBSCertificate component. A field after
        // the [3] field is not valid and could hide data from a stricter
        // parser, so fail closed instead of ignoring it.
        guard tbsFields.isAtEnd else { return nil }

        // Extensions ::= SEQUENCE OF Extension
        // Extension ::= SEQUENCE { extnID OID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }
        var extensionsCursor = DERCursor(extensionsField)
        guard let extensionsSequence = extensionsCursor.next(), extensionsSequence.tag == 0x30,
              extensionsCursor.isAtEnd else {
            return nil
        }
        var parsed = ParsedExtensions()
        var extensionCursor = DERCursor(extensionsSequence.content)
        while let extensionElement = extensionCursor.next() {
            guard extensionElement.tag == 0x30 else { return nil }
            var fields = DERCursor(extensionElement.content)
            guard let oid = fields.next(), oid.tag == 0x06,
                  isMinimalDEROID(oid.content) else { return nil }
            let recognized = oid.content == [0x55, 0x1D, 0x11]
                || oid.content == [0x55, 0x1D, 0x25]
                || oid.content == [0x55, 0x1D, 0x0F]
                || oid.content == [0x55, 0x1D, 0x13]
            guard recognized else { continue }
            // Reject a repeated recognized extension instead of letting a
            // later value mask an earlier one (e.g. basicConstraints CA:TRUE
            // followed by CA:FALSE).
            guard parsed.recognizedExtensionOIDs.insert(oid.content).inserted else {
                return nil
            }

            var valueElement = fields.next()
            if valueElement?.tag == 0x01 {
                valueElement = fields.next()
            }
            // A recognized extension with a malformed value fails closed.
            guard let extnValue = valueElement, extnValue.tag == 0x04 else { return nil }
            // The extension must be exactly OID + [critical] + extnValue: a
            // trailing field would be ignored by this walker while another
            // parser could read it.
            guard fields.isAtEnd else { return nil }

            switch oid.content {
            case [0x55, 0x1D, 0x11]:  // 2.5.29.17 subjectAltName
                guard parseSubjectAltName(extnValue.content, into: &parsed) else { return nil }
            case [0x55, 0x1D, 0x25]:  // 2.5.29.37 extendedKeyUsage
                parsed.hasExtendedKeyUsage = true
                guard parseExtendedKeyUsage(extnValue.content, into: &parsed) else { return nil }
            case [0x55, 0x1D, 0x0F]:  // 2.5.29.15 keyUsage
                guard parseKeyUsage(extnValue.content, into: &parsed) else { return nil }
            case [0x55, 0x1D, 0x13]:  // 2.5.29.19 basicConstraints
                guard parseBasicConstraints(extnValue.content, into: &parsed) else { return nil }
            default:
                continue
            }
        }
        // A malformed element ends `next()` early; a truncated extension list
        // must fail closed rather than decide on a prefix of it.
        guard extensionCursor.isAtEnd else { return nil }
        return parsed
    }

    /// GeneralNames ::= SEQUENCE OF GeneralName; [2] dNSName, [7] iPAddress
    private static func parseSubjectAltName(_ content: [UInt8], into parsed: inout ParsedExtensions) -> Bool {
        var generalNamesCursor = DERCursor(content)
        guard let generalNames = generalNamesCursor.next(), generalNames.tag == 0x30,
              generalNamesCursor.isAtEnd else {
            return false
        }
        var namesCursor = DERCursor(generalNames.content)
        while let name = namesCursor.next() {
            switch name.tag {
            case 0x82:
                if let string = String(bytes: name.content, encoding: .utf8) {
                    parsed.dnsNames.append(string)
                }
            case 0x87:
                parsed.ipAddresses.append(Data(name.content))
            default:
                continue
            }
        }
        // A truncated name ends `next()` early; the list must be fully
        // consumed (and parseable) before it is trusted.
        guard namesCursor.isAtEnd else { return false }
        return true
    }

    /// ExtKeyUsageSyntax ::= SEQUENCE SIZE (1..MAX) OF KeyPurposeId
    private static func parseExtendedKeyUsage(_ content: [UInt8], into parsed: inout ParsedExtensions) -> Bool {
        var sequenceCursor = DERCursor(content)
        guard let sequence = sequenceCursor.next(), sequence.tag == 0x30,
              sequenceCursor.isAtEnd else {
            return false
        }
        var oidCursor = DERCursor(sequence.content)
        while let oid = oidCursor.next() {
            guard oid.tag == 0x06 else { return false }
            parsed.extendedKeyUsageOIDs.append(oid.content)
        }
        guard oidCursor.isAtEnd else { return false }
        return true
    }

    /// KeyUsage ::= BIT STRING (the first payload byte holds the unused-bits count).
    ///
    /// The unused-bits count is validated (DER allows 0…7, and the unused
    /// trailing bits must be zero) so a malformed extension cannot smuggle in
    /// a bit position that does not mean what the caller expects. Trailing
    /// elements after the BIT STRING fail closed.
    private static func parseKeyUsage(_ content: [UInt8], into parsed: inout ParsedExtensions) -> Bool {
        var bitStringCursor = DERCursor(content)
        guard let bitString = bitStringCursor.next(), bitString.tag == 0x03,
              !bitString.content.isEmpty, bitStringCursor.isAtEnd else {
            return false
        }
        let unusedBits = bitString.content[0]
        guard unusedBits <= 7 else { return false }
        let payload = Array(bitString.content.dropFirst())
        if unusedBits > 0 {
            guard let last = payload.last else { return false }
            let mask = UInt8((1 << unusedBits) - 1)
            guard (last & mask) == 0 else { return false }
        }
        parsed.keyUsageBits = payload
        return true
    }

    /// BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE,
    ///   pathLenConstraint INTEGER OPTIONAL }. DER encodes `cA` as an
    /// explicit BOOLEAN when present (TRUE = 0xFF).
    ///
    /// A first-element-only walker would read `SEQUENCE { BOOLEAN FALSE,
    /// BOOLEAN TRUE }` as non-CA while another parser could read CA:TRUE, so
    /// every element after `cA` must be the optional pathLenConstraint and
    /// the sequence must be exhausted.
    private static func parseBasicConstraints(_ content: [UInt8], into parsed: inout ParsedExtensions) -> Bool {
        var outerCursor = DERCursor(content)
        guard let sequence = outerCursor.next(), sequence.tag == 0x30,
              outerCursor.isAtEnd else {
            return false
        }
        parsed.basicConstraintsIsCA = false
        var fieldsCursor = DERCursor(sequence.content)
        guard let first = fieldsCursor.next() else {
            // Empty SEQUENCE: cA defaults to FALSE — but only when the walk
            // actually ended cleanly. A malformed non-empty sequence whose
            // first element cannot be read is not an empty sequence.
            return fieldsCursor.isAtEnd
        }
        guard first.tag == 0x01, first.content.count == 1 else {
            // pathLenConstraint without cA is not valid DER (it requires
            // cA TRUE); fail closed.
            return false
        }
        parsed.basicConstraintsIsCA = first.content[0] != 0
        if let pathLenConstraint = fieldsCursor.next() {
            // pathLenConstraint is only valid when cA is TRUE, and DER
            // encodes it as a non-negative, minimally-encoded INTEGER.
            guard parsed.basicConstraintsIsCA == true,
                  pathLenConstraint.tag == 0x02,
                  isMinimalNonNegativeInteger(pathLenConstraint.content) else {
                return false
            }
        }
        guard fieldsCursor.isAtEnd else { return false }
        return true
    }

    /// Minimal DER non-negative INTEGER: non-empty, sign bit clear, and no
    /// redundant leading 0x00 (allowed only when the next byte would
    /// otherwise read as negative). A non-minimal encoding of the
    /// pathLenConstraint could be read differently by another parser, so it
    /// fails closed.
    private static func isMinimalNonNegativeInteger(_ content: [UInt8]) -> Bool {
        guard let first = content.first, first & 0x80 == 0 else { return false }
        if content.count > 1, first == 0x00 {
            return content[1] & 0x80 != 0
        }
        return true
    }

    /// Minimal DER OBJECT IDENTIFIER: non-empty, every base-128 subidentifier
    /// ends with a byte whose high bit is clear, and no subidentifier starts
    /// with a redundant 0x80 group. A non-minimal encoding of a recognized
    /// OID would be skipped here while another parser reads it as that
    /// extension, so it must fail closed instead.
    private static func isMinimalDEROID(_ content: [UInt8]) -> Bool {
        guard !content.isEmpty else { return false }
        var atSubidentifierStart = true
        for byte in content {
            if atSubidentifierStart && byte == 0x80 { return false }
            atSubidentifierStart = (byte & 0x80) == 0
        }
        return atSubidentifierStart
    }

    /// The subjectAltName DNS names and IP addresses of the leaf.
    private static func subjectAltNameEntries(
        _ certificate: SecCertificate
    ) -> (dnsNames: [String], ipAddresses: [Data])? {
        guard let parsed = parseExtensions(certificate) else { return nil }
        return (parsed.dnsNames, parsed.ipAddresses)
    }

    /// Minimal definite-length DER reader for the extension walk above.
    private struct DERCursor {
        private let bytes: [UInt8]
        private var offset = 0
        /// Set when a tag or length could not be read (dangling tag,
        /// truncated long-form length, or a length that overruns the
        /// buffer). The offset can still reach the end in those cases, so
        /// `isAtEnd` must not treat them as a clean end.
        private var parseFailed = false

        init(_ data: Data) { bytes = [UInt8](data) }
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> (tag: UInt8, content: [UInt8])? {
            guard offset < bytes.count else { return nil }
            let tag = bytes[offset]
            // High-tag-number form (low 5 bits all set): this walker only
            // understands single-byte low tags, and reading the following
            // identifier byte as a length would misparse the element. Fail
            // closed instead of guessing.
            guard tag & 0x1F != 0x1F else {
                parseFailed = true
                return nil
            }
            offset += 1
            guard let length = readLength(), offset + length <= bytes.count else {
                parseFailed = true
                return nil
            }
            let content = Array(bytes[offset..<(offset + length)])
            offset += length
            return (tag, content)
        }

        private mutating func readLength() -> Int? {
            guard offset < bytes.count else {
                parseFailed = true
                return nil
            }
            let first = bytes[offset]
            offset += 1
            if first < 0x80 { return Int(first) }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 3, offset + byteCount <= bytes.count else {
                parseFailed = true
                return nil
            }
            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
            // DER requires the minimum number of length octets (X.690
            // §8.1.3.5): the long form applies only to values >= 0x80, and
            // the first length octet must be non-zero (no leading zeros). A
            // non-minimal encoding would let two byte strings denote the
            // same length, so fail closed.
            guard length >= 0x80, bytes[offset - byteCount] != 0x00 else {
                parseFailed = true
                return nil
            }
            return length
        }

        /// True only when every byte was consumed by a fully successful walk.
        /// `next()` returns nil both for a clean end and for a malformed
        /// tag/length; `parseFailed` distinguishes the latter so callers fail
        /// closed instead of accepting the successfully-read prefix.
        var isAtEnd: Bool { !parseFailed && offset >= bytes.count }
    }

    /// Build the `sec_protocol_verify_t` block used by both ALPN transports.
    ///
    /// The block reads the negotiated ALPN from the protocol metadata (the
    /// SDK offers no metadata factory, so metadata extraction itself stays
    /// untested; the decision logic is exercised directly through `verify`).
    static func makeVerifyBlock(
        anchors: [SecCertificate],
        serverNames: [String],
        allowedALPNs: [String],
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
                allowedALPNs: allowedALPNs
            )
            if !result.ok {
                let nameList = serverNames.joined(separator: ",")
                let alpnList = allowedALPNs.joined(separator: ",")
                let errorDescription = result.error.map { String(describing: $0) } ?? "unknown"
                logger.error(
                    "teleport_tls_verify_failed server_names=\(nameList, privacy: .private(mask: .hash)) alpn=\(negotiatedALPN ?? "nil", privacy: .public) allowed_alpn=\(alpnList, privacy: .public) error=\(errorDescription, privacy: .private(mask: .hash))"
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
