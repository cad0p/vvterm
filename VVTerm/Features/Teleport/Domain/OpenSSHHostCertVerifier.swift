// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  OpenSSHHostCertVerifier.swift
//  VVTerm
//
//  Verification of SSH host certificates against the cluster Host CA.
//
//  Teleport presents SSH *certificates* for host identities: the proxy and
//  every node sign their host key with the cluster Host CA. The Host CA SSH
//  public keys arrive as `host_signers[].checking_keys` (authorized_keys
//  lines) and are pinned at bootstrap (additions-only refresh on login).
//
//  Verification checks, in order:
//    1. the blob is an OpenSSH *host* certificate;
//    2. it is currently valid (tolerating the clock skew Teleport itself
//       absorbs by backdating);
//    3. at least one principal exactly matches an expected principal;
//    4. its signature key equals one of the pinned Host CA keys;
//    5. the CA signature over the signed certificate body verifies.
//
//  Supported CA key types: `ssh-ed25519` and `ecdsa-sha2-nistp256`.
//  RSA CA keys are reported as `.unsupportedCAKeyType` (fail closed with an
//  actionable error) until a need is demonstrated.
//

import Foundation
import CryptoKit

enum OpenSSHHostCertVerification: Equatable {
    /// The host certificate chains to a pinned Host CA key and is valid.
    case verified
    /// The blob is not an OpenSSH host certificate (plain host key, user
    /// certificate, malformed blob, …).
    case notACertificate
    /// The certificate's signature key is not one of the pinned Host CA keys.
    case noMatchingCAKey
    /// The CA signature over the certificate body did not verify.
    case badSignature
    /// Outside the certificate validity window.
    case expired
    /// No certificate principal matches an expected principal.
    case principalMismatch
    /// The matched Host CA key type is not supported yet.
    case unsupportedCAKeyType(String)
}

enum OpenSSHHostCertVerifier {

    /// Verify a host key blob (as returned by `libssh2_session_hostkey`)
    /// against the pinned Host CA checking keys.
    static func verify(
        hostKeyBlob: Data,
        expectedPrincipals: [String],
        checkingKeys: [String],
        now: Date,
        clockSkew: TimeInterval = 60
    ) -> OpenSSHHostCertVerification {
        guard let cert = OpenSSHCertificate.parse(blob: hostKeyBlob),
              cert.certType == .host else {
            return .notACertificate
        }
        // Teleport backdates validAfter to absorb clock skew; validBefore is
        // the hard expiry (no skew tolerance).
        let validAfterOK = cert.validAfterDate <= now.addingTimeInterval(clockSkew)
        let validBeforeOK = now < cert.validBeforeDate
        guard validAfterOK, validBeforeOK else {
            return .expired
        }
        guard !expectedPrincipals.isEmpty,
              cert.validPrincipals.contains(where: { expectedPrincipals.contains($0) }) else {
            return .principalMismatch
        }

        let parsedCAKeys = checkingKeys.compactMap { line -> HostCAKey? in
            guard let (_, blob) = OpenSSHCertificate.parseAuthorizedKeysLine(line) else { return nil }
            return HostCAKey(blob: blob)
        }
        guard let caKey = parsedCAKeys.first(where: { $0.blob == cert.signatureKeyBlob }) else {
            return .noMatchingCAKey
        }

        switch caKey.verify(signatureBlob: cert.signatureBlob, over: cert.signedData) {
        case .valid:
            return .verified
        case .invalid:
            return .badSignature
        case .unsupportedType(let type):
            return .unsupportedCAKeyType(type)
        }
    }
}

// MARK: - Host CA keys

private struct HostCAKey {
    enum Verification {
        case valid
        case invalid
        case unsupportedType(String)
    }

    let blob: Data
    private let keyType: String
    /// The key material after the type string (curve+Q for ECDSA, the raw
    /// public key for ed25519).
    private let keyMaterial: Data

    init?(blob: Data) {
        var reader = SSHBlobReader(data: blob)
        guard let typeData = reader.readString(),
              let keyType = String(data: typeData, encoding: .utf8),
              let material = reader.readString() else {
            return nil
        }
        self.blob = blob
        self.keyType = keyType
        // The key material after the type string (curve+Q for ECDSA, the raw
        // public key for ed25519).
        self.keyMaterial = material
    }

    func verify(signatureBlob: Data, over signedData: Data) -> Verification {
        var reader = SSHBlobReader(data: signatureBlob)
        guard let sigTypeData = reader.readString(),
              let sigType = String(data: sigTypeData, encoding: .utf8),
              let sigData = reader.readString() else {
            return .invalid
        }

        switch keyType {
        case "ssh-ed25519":
            guard sigType == "ssh-ed25519" else { return .invalid }
            // ed25519 key material is the raw 32-byte public key.
            guard keyMaterial.count == 32,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyMaterial) else {
                return .invalid
            }
            return publicKey.isValidSignature(sigData, for: signedData) ? .valid : .invalid

        case "ecdsa-sha2-nistp256":
            guard sigType == "ecdsa-sha2-nistp256" else { return .invalid }
            var keyReader = SSHBlobReader(data: keyMaterial)
            guard let curveData = keyReader.readString(),
                  let curve = String(data: curveData, encoding: .utf8),
                  curve == "nistp256",
                  let point = keyReader.readString(),
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else {
                return .invalid
            }
            guard let signature = Self.ecdsaSignature(from: sigData) else {
                return .invalid
            }
            return publicKey.isValidSignature(signature, for: signedData) ? .valid : .invalid

        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            return .unsupportedType(keyType)

        default:
            return .unsupportedType(keyType)
        }
    }

    /// Parse the OpenSSH ECDSA signature encoding (`mpint r || mpint s`) into
    /// CryptoKit's raw (r||s) representation.
    private static func ecdsaSignature(from sigData: Data) -> P256.Signing.ECDSASignature? {
        var reader = SSHBlobReader(data: sigData)
        guard let r = reader.readString(), let s = reader.readString() else { return nil }
        let r32 = leftPadded32(r)
        let s32 = leftPadded32(s)
        return try? P256.Signing.ECDSASignature(rawRepresentation: r32 + s32)
    }

    /// mpints may carry a leading zero byte (or be shorter than 32 bytes);
    /// normalize to exactly 32 bytes.
    private static func leftPadded32(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0x00 }))
        if bytes.count > 32 {
            bytes = bytes.suffix(32)
        }
        if bytes.count < 32 {
            bytes = Data(repeating: 0, count: 32 - bytes.count) + bytes
        }
        return bytes
    }
}

// MARK: - Blob reading

/// Minimal SSH string reader (mirrors the private reader in
/// `OpenSSHCertificate`; kept separate because the verifier needs to keep
/// the raw remaining bytes).
private struct SSHBlobReader {
    let data: Data
    private(set) var offset: Int = 0

    var remainingData: Data {
        guard offset < data.count else { return Data() }
        let start = data.startIndex + offset
        return Data(data[start..<data.endIndex])
    }

    mutating func readString() -> Data? {
        guard offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        let length = Int(UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3]))
        offset += 4
        guard offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += length
        return Data(data[start..<(start + length)])
    }
}
