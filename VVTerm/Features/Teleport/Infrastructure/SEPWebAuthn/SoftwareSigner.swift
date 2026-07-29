// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  SoftwareSigner.swift
//  SEPWebAuthn
//
//  Part A signer — pure software P-256 via CryptoKit. No Secure Enclave, no
//  biometry, no codesigning. Runs on any platform with CryptoKit (macOS 10.15+,
//  iOS 13+). On the `macos-14` GitHub Actions runner this builds and signs
//  without entitlements.

import Foundation
import CryptoKit

/// Software P-256 signer. Holds keys in-memory in a dictionary keyed by the
/// credential ID. The credential ID is a random 32-byte value generated at
/// `createKey` time (no persistence — the spike re-creates per run).
public final class SoftwareSigner: WebAuthnSigner {
    public let label = "software"

    private var keys: [Data: P256.Signing.PrivateKey] = [:]
    private let queue = DispatchQueue(label: "sep-webauthn.software-signer")

    public init() {}

    public func createKey() throws -> (credentialID: Data, publicKeyRaw: Data) {
        let id = newCredentialID()
        let key = P256.Signing.PrivateKey()
        let raw = key.publicKey.x963Representation  // 0x04 || X(32) || Y(32)
        queue.sync { keys[id] = key }
        return (id, raw)
    }

    public func sign(message: Data, credentialID: Data) throws -> Data {
        let key: P256.Signing.PrivateKey? = queue.sync { keys[credentialID] }
        guard let key else { throw SignerError.keyNotFound }
        // CryptoKit's signature(for: Data) hashes the input with SHA-256
        // internally, producing a signature over sha256(message). The
        // server computes the same sha256(authData || clientDataHash) and
        // verifies — single hash, no double-hashing.
        //
        // Returns DER-encoded ASN.1 SEQUENCE { r INTEGER, s INTEGER } —
        // matching what SecKeyCreateSignature returns (see
        // SecureEnclaveSigner.sign).
        let signature = try key.signature(for: message)
        return signature.derRepresentation
    }
}
