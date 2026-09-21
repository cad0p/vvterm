// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  OpenSSHCertificate.swift
//  VVTerm
//
//  Parser for the OpenSSH SSH certificate wire format (PROTOCOL.certkeys).
//
//  Teleport issues OpenSSH SSH certificates for user logins and for host
//  identities (proxy + nodes). The certificate is an authorized_keys-style
//  line:
//
//      ssh-ed25519-cert-v01@openssh.com <base64(blob)> [comment]
//
//  The base64 decodes to (see OpenSSH PROTOCOL.certkeys):
//
//      string    cert key type        ("ssh-ed25519-cert-v01@openssh.com")
//      string    nonce
//      <public key fields>            (ed25519: 1 string; ecdsa: curve+Q;
//                                      rsa: e + n)
//      uint64    serial
//      uint32    type                 (1 = user, 2 = host)
//      string    key id
//      string    valid principals     (comma-separated)
//      uint64    valid after
//      uint64    valid before
//      string    critical options
//      string    extensions
//      string    reserved
//      string    signature key        (the CA public key blob)
//      string    signature            (over everything above)
//
//  The previous `SSHCertExpiryParser` implementation walked the fields in the
//  wrong order (it read the signature + validity *before* the extensions and
//  skipped exactly one string for the public key, which is only correct for
//  ed25519). The walker below is the corrected, pure, key-type-aware parser
//  used by the expiry parser, the issued-cert binding check, and the host
//  certificate verifier.
//

import Foundation

/// A parsed OpenSSH SSH certificate.
struct OpenSSHCertificate: Equatable, Sendable {

    /// The certificate type field: 1 = user certificate, 2 = host certificate.
    enum CertType: UInt32, Sendable, Equatable {
        case user = 1
        case host = 2
    }

    /// The full certificate key type, e.g.
    /// `ssh-ed25519-cert-v01@openssh.com`.
    let certKeyType: String
    /// The certificate nonce.
    let nonce: Data
    /// The certified public key as a plain OpenSSH key blob
    /// (`ssh-ed25519 <pubkey>`, `ecdsa-sha2-nistp256 <curve> <Q>`,
    /// `ssh-rsa <e> <n>`) — the same bytes as the second field of an
    /// authorized_keys line, so it can be compared byte-for-byte with the
    /// key the client generated.
    let publicKeyBlob: Data
    let serial: UInt64
    let certType: CertType
    let keyID: String
    /// The certificate principals. Empty when the cert carries no principals.
    let validPrincipals: [String]
    /// Unix timestamp (seconds).
    let validAfter: UInt64
    /// Unix timestamp (seconds). 0 means "no expiry".
    let validBefore: UInt64
    /// Raw `critical options` payload (encoded name/data tuples).
    let criticalOptions: Data
    /// Raw `extensions` payload (encoded name/data tuples).
    let extensions: Data
    /// The reserved field (empty in practice).
    let reserved: Data
    /// The CA public key blob (the `signature key` field).
    let signatureKeyBlob: Data
    /// The CA signature blob (the `signature` field).
    let signatureBlob: Data
    /// The bytes covered by the CA signature: the certificate blob up to (but
    /// excluding) the `signature` field's length prefix.
    let signedData: Data

    /// `validAfter` as a `Date`.
    var validAfterDate: Date {
        Date(timeIntervalSince1970: TimeInterval(validAfter))
    }

    /// `validBefore` as a `Date`; `.distantFuture` when the cert has no
    /// expiry (`validBefore == 0`).
    var validBeforeDate: Date {
        validBefore == 0 ? .distantFuture : Date(timeIntervalSince1970: TimeInterval(validBefore))
    }

    /// Whether the certificate is currently within its validity window,
    /// optionally tolerating clock skew on both ends.
    func isValid(at date: Date, clockSkew: TimeInterval = 0) -> Bool {
        let after = validAfterDate.addingTimeInterval(-clockSkew)
        guard date >= after else { return false }
        if validBefore == 0 { return true }
        return date < validBeforeDate.addingTimeInterval(clockSkew)
    }

    // MARK: - Parsing

    /// Parse a certificate from either an authorized_keys-style line, a PEM
    /// block (`-----BEGIN SSH CERTIFICATE-----`), or a bare base64 blob.
    static func parse(authorizedKeysOrPEM input: String) -> OpenSSHCertificate? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // PEM block: strip the header/footer lines and decode the body.
        if trimmed.contains("-----BEGIN") {
            let body = trimmed
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { !$0.hasPrefix("-----") }
                .joined()
            guard let blob = Data(base64Encoded: body) else { return nil }
            return parse(blob: blob)
        }

        // authorized_keys line: "<type> <base64> [comment]".
        if trimmed.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            guard let (_, blob) = parseAuthorizedKeysLine(trimmed) else { return nil }
            return parse(blob: blob)
        }

        // Bare base64 blob.
        guard let blob = Data(base64Encoded: trimmed) else { return nil }
        return parse(blob: blob)
    }

    /// Parse an authorized_keys / known_hosts-style line into its key type and
    /// decoded key blob. Handles leading options and the `@cert-authority`
    /// known_hosts marker by scanning for the first field that looks like an
    /// SSH key type.
    static func parseAuthorizedKeysLine(_ line: String) -> (keyType: String, blob: Data)? {
        let fields = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }

        for index in 0..<(fields.count - 1) {
            let candidate = String(fields[index])
            guard candidate.hasPrefix("ssh-") || candidate.hasPrefix("sk-") || candidate.hasPrefix("ecdsa-sha2-") else { continue }
            guard !candidate.hasPrefix("ssh-dss") else { continue }
            guard let blob = Data(base64Encoded: String(fields[index + 1])) else { continue }
            return (candidate, blob)
        }
        return nil
    }

    /// Parse a certificate from its decoded wire blob.
    static func parse(blob: Data) -> OpenSSHCertificate? {
        var reader = BlobReader(data: blob)

        // 1. cert key type — must be a `-cert-v01@openssh.com` type.
        guard let typeData = reader.readString(),
              let certKeyType = String(data: typeData, encoding: .utf8) else {
            return nil
        }
        guard let keyKind = CertificateKeyKind(certKeyType: certKeyType) else {
            return nil
        }

        // 2. nonce.
        guard let nonce = reader.readString() else { return nil }

        // 3. public key fields (key-type aware).
        let publicKeyStart = reader.offset
        for _ in 0..<keyKind.publicKeyFieldCount {
            guard reader.readString() != nil else { return nil }
        }
        guard let publicKeyFields = reader.data(
            in: publicKeyStart..<reader.offset
        ) else { return nil }
        var publicKeyBlob = sshString(Data(keyKind.plainKeyType.utf8))
        publicKeyBlob.append(publicKeyFields)

        // 4. serial.
        guard let serial = reader.readUInt64() else { return nil }

        // 5. type (1 = user, 2 = host).
        guard let rawType = reader.readUInt32(),
              let certType = CertType(rawValue: rawType) else {
            return nil
        }

        // 6. key id.
        guard let keyIDData = reader.readString(),
              let keyID = String(data: keyIDData, encoding: .utf8) else {
            return nil
        }

        // 7. valid principals: one string whose payload is a concatenated
        //    sequence of SSH strings (OpenSSH PROTOCOL.certkeys — there is no
        //    element count).
        guard let principalsBlob = reader.readString() else { return nil }
        var principalsReader = BlobReader(data: principalsBlob)
        var validPrincipals: [String] = []
        while principalsReader.remaining > 0 {
            guard let principalData = principalsReader.readString(),
                  let principal = String(data: principalData, encoding: .utf8) else {
                return nil
            }
            validPrincipals.append(principal)
        }

        // 8. valid after / valid before.
        guard let validAfter = reader.readUInt64(),
              let validBefore = reader.readUInt64() else {
            return nil
        }

        // 9. critical options / extensions / reserved.
        guard let criticalOptions = reader.readString(),
              let extensions = reader.readString(),
              let reserved = reader.readString() else {
            return nil
        }

        // 10. signature key.
        guard let signatureKeyBlob = reader.readString() else { return nil }

        // The signature covers everything parsed so far, including the
        // signature key but excluding the signature field itself.
        guard let signedData = reader.data(in: 0..<reader.offset) else { return nil }

        // 11. signature.
        guard let signatureBlob = reader.readString() else { return nil }

        // The certificate blob must end after the signature.
        guard reader.remaining == 0 else { return nil }

        return OpenSSHCertificate(
            certKeyType: certKeyType,
            nonce: nonce,
            publicKeyBlob: publicKeyBlob,
            serial: serial,
            certType: certType,
            keyID: keyID,
            validPrincipals: validPrincipals,
            validAfter: validAfter,
            validBefore: validBefore,
            criticalOptions: criticalOptions,
            extensions: extensions,
            reserved: reserved,
            signatureKeyBlob: signatureKeyBlob,
            signatureBlob: signatureBlob,
            signedData: signedData
        )
    }

    /// SSH wire helper: `uint32_be(length) || payload`.
    static func sshString(_ data: Data) -> Data {
        var out = Data()
        let length = UInt32(data.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(data)
        return out
    }

    // MARK: - Key kinds

    private struct CertificateKeyKind {
        let plainKeyType: String
        let publicKeyFieldCount: Int

        init?(certKeyType: String) {
            let suffix = "-cert-v01@openssh.com"
            guard certKeyType.hasSuffix(suffix) else { return nil }
            var plain = String(certKeyType.dropLast(suffix.count))
            switch plain {
            case "ssh-ed25519":
                self.publicKeyFieldCount = 1
            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                self.publicKeyFieldCount = 2
            case "rsa-sha2-256", "rsa-sha2-512":
                // RSA certificates are always issued with the `ssh-rsa` key
                // type; the rsa-sha2-* names appear in signature algorithms.
                plain = "ssh-rsa"
                self.publicKeyFieldCount = 2
            case "ssh-rsa":
                self.publicKeyFieldCount = 2
            default:
                // Unknown key kinds fail closed — the caller cannot bind or
                // verify a key blob it does not understand.
                return nil
            }
            self.plainKeyType = plain
        }
    }

    // MARK: - Blob reading

    private struct BlobReader {
        let data: Data
        private(set) var offset: Int = 0

        var remaining: Int { data.count - offset }

        mutating func readUInt32() -> UInt32? {
            guard remaining >= 4 else { return nil }
            let base = data.startIndex + offset
            let value = UInt32(data[base]) << 24
                | UInt32(data[base + 1]) << 16
                | UInt32(data[base + 2]) << 8
                | UInt32(data[base + 3])
            offset += 4
            return value
        }

        mutating func readUInt64() -> UInt64? {
            guard remaining >= 8 else { return nil }
            var value: UInt64 = 0
            for index in 0..<8 {
                value = (value << 8) | UInt64(data[data.startIndex + offset + index])
            }
            offset += 8
            return value
        }

        mutating func readString() -> Data? {
            guard let length = readUInt32() else { return nil }
            let count = Int(length)
            guard remaining >= count else { return nil }
            let start = data.startIndex + offset
            offset += count
            return Data(data[start..<(start + count)])
        }

        func data(in range: Range<Int>) -> Data? {
            guard range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
            let start = data.startIndex + range.lowerBound
            let end = data.startIndex + range.upperBound
            return Data(data[start..<end])
        }
    }
}
