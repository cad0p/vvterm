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
//  Supported CA key types: `ssh-ed25519`, `ecdsa-sha2-nistp256`, and
//  `ssh-rsa`/`rsa-sha2-256`/`rsa-sha2-512`. RSA CAs (Teleport's legacy
//  signature suite) are verified through the Security framework, which has
//  no CryptoKit equivalent.
//

import Foundation
import CryptoKit
import Security

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
        // the hard expiry (no skew tolerance). A zero validBefore means "no
        // expiry" in the OpenSSH wire format; an open-ended host certificate
        // is never acceptable, so it is treated as invalid.
        let validAfterOK = cert.validAfterDate <= now.addingTimeInterval(clockSkew)
        let validBeforeOK = cert.validBefore != 0 && now < cert.validBeforeDate
        guard validAfterOK, validBeforeOK else {
            return .expired
        }
        // Drop empty expectations: a zero-length principal in the
        // certificate must never satisfy the principal check.
        let expected = expectedPrincipals.filter { !$0.isEmpty }
        guard !expected.isEmpty,
              cert.validPrincipals.contains(where: { expected.contains($0) }) else {
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
              let keyType = String(data: typeData, encoding: .utf8) else {
            return nil
        }
        // The key-type-specific material follows the type string:
        //   ssh-ed25519         → the raw 32-byte public key
        //   ecdsa-sha2-nistp256 → string(curve) + string(point)
        //   ssh-rsa/rsa-sha2-*  → mpint(e) + mpint(n)
        // Keep the remaining blob intact and validate the exact layout per
        // key type at verification time, so trailing bytes cannot be
        // silently ignored (and RSA's two-string layout is not rejected).
        let material = reader.remainingData
        guard !material.isEmpty else { return nil }
        self.blob = blob
        self.keyType = keyType
        self.keyMaterial = material
    }

    func verify(signatureBlob: Data, over signedData: Data) -> Verification {
        var reader = SSHBlobReader(data: signatureBlob)
        guard let sigTypeData = reader.readString(),
              let sigType = String(data: sigTypeData, encoding: .utf8),
              let sigData = reader.readString() else {
            return .invalid
        }
        // A signature blob is exactly string(type) + string(signature);
        // trailing garbage must not be ignored.
        guard reader.remainingData.isEmpty else { return .invalid }

        switch keyType {
        case "ssh-ed25519":
            guard sigType == "ssh-ed25519" else { return .invalid }
            var keyReader = SSHBlobReader(data: keyMaterial)
            // The material is exactly string(32-byte public key): trailing
            // bytes must not be ignored.
            guard let key = keyReader.readString(),
                  keyReader.remainingData.isEmpty,
                  key.count == 32,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else {
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
                  // The material is exactly string(curve) + string(point):
                  // trailing bytes must not be ignored.
                  keyReader.remainingData.isEmpty,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: point) else {
                return .invalid
            }
            guard let signature = Self.ecdsaSignature(from: sigData) else {
                return .invalid
            }
            return publicKey.isValidSignature(signature, for: signedData) ? .valid : .invalid

        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            // The CA signs with its RSA key; the signature blob's type
            // selects the digest (ssh-rsa = SHA-1, rsa-sha2-* = SHA-256/512).
            var keyReader = SSHBlobReader(data: keyMaterial)
            guard let exponent = keyReader.readString(),
                  let modulus = keyReader.readString(),
                  // The material is exactly mpint(e) + mpint(n): trailing
                  // bytes must not be ignored.
                  keyReader.remainingData.isEmpty,
                  let publicKey = Self.rsaPublicKey(exponent: exponent, modulus: modulus) else {
                return .invalid
            }
            let algorithm: SecKeyAlgorithm
            switch sigType {
            case "ssh-rsa": algorithm = .rsaSignatureMessagePKCS1v15SHA1
            case "rsa-sha2-256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
            case "rsa-sha2-512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
            default: return .invalid
            }
            var error: Unmanaged<CFError>?
            let valid = SecKeyVerifySignature(
                publicKey,
                algorithm,
                signedData as CFData,
                sigData as CFData,
                &error
            )
            return valid ? .valid : .invalid

        default:
            return .unsupportedType(keyType)
        }
    }

    /// Parse the OpenSSH ECDSA signature encoding (`mpint r || mpint s`) into
    /// CryptoKit's raw (r||s) representation.
    private static func ecdsaSignature(from sigData: Data) -> P256.Signing.ECDSASignature? {
        guard let raw = OpenSSHECDSASignature.rawSignature(from: sigData) else { return nil }
        return try? P256.Signing.ECDSASignature(rawRepresentation: raw)
    }

    /// Build a Security-framework RSA public key from OpenSSH mpints.
    ///
    /// `SecKeyCreateWithData` expects the PKCS#1 `RSAPublicKey` DER
    /// (`SEQUENCE { modulus INTEGER, publicExponent INTEGER }`), assembled
    /// here with minimal DER writers: SSH mpints are big-endian two's
    /// complement, which matches DER's INTEGER rules once a leading zero is
    /// added for a high bit.
    private static func rsaPublicKey(exponent: Data, modulus: Data) -> SecKey? {
        guard !exponent.isEmpty, !modulus.isEmpty else { return nil }
        let der = derTLV(0x30, derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    private static func derInteger(_ value: Data) -> Data {
        var bytes = Data(value.drop(while: { $0 == 0x00 }))
        if bytes.isEmpty { bytes = Data([0x00]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes = Data([0x00]) + bytes }
        return derTLV(0x02, bytes)
    }

    private static func derTLV(_ tag: UInt8, _ content: Data) -> Data {
        let length: Data
        let count = content.count
        if count < 0x80 {
            length = Data([UInt8(count)])
        } else {
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            length = Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
        }
        return Data([tag]) + length + content
    }
}

// MARK: - ECDSA signature encoding

/// The OpenSSH ECDSA signature encoding helpers, kept pure so the bounds
/// rules are unit-testable without a live verifier.
enum OpenSSHECDSASignature {

    /// Parse `mpint r || mpint s` into a fixed 64-byte (r||s) representation.
    ///
    /// mpints may carry a leading zero byte (or be shorter than 32 bytes);
    /// normalize to exactly 32 bytes. A component longer than 32 bytes after
    /// stripping leading zeros is not a valid P-256 scalar and is rejected —
    /// never silently truncated.
    static func rawSignature(from sigData: Data) -> Data? {
        var reader = SSHBlobReader(data: sigData)
        guard let r = reader.readString(), let s = reader.readString(),
              let r32 = normalized32(r), let s32 = normalized32(s) else {
            return nil
        }
        guard reader.remainingData.isEmpty else { return nil }
        return r32 + s32
    }

    /// Normalize an mpint to exactly 32 bytes, rejecting oversized values.
    static func normalized32(_ value: Data) -> Data? {
        var bytes = Data(value.drop(while: { $0 == 0x00 }))
        guard bytes.count <= 32 else { return nil }
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
