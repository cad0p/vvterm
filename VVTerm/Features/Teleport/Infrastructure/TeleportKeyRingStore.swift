//
//  TeleportKeyRingStore.swift
//  VVTerm
//
//  Persists the Teleport KeyRing (SSH cert + keypairs + Host CA bundle) in the iOS Keychain.
//  V1 uses basic Keychain storage; Secure Enclave for private keys + refresh-before-expiry
//  are session 3 (cert lifecycle).
//

import Foundation
import Security

enum TeleportKeyRingStoreError: LocalizedError {
    case keychainError(OSStatus, String)
    case notFound
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .keychainError(let status, let operation):
            return "Keychain \(operation) failed (OSStatus \(status))"
        case .notFound:
            return "No Teleport KeyRing stored."
        case .decodeFailed:
            return "Stored Teleport KeyRing could not be decoded."
        }
    }
}

/// Stores and retrieves the Teleport KeyRing in the iOS Keychain.
/// All fields are stored under a single Keychain item keyed by proxy host, as JSON.
final class TeleportKeyRingStore {

    static let shared = TeleportKeyRingStore()

    private init() {}

    private let service = "app.vivy.VivyTerm.teleport"

    private func account(for proxyHost: String) -> String {
        "keyring@\(proxyHost)"
    }

    // MARK: - Store

    func store(_ keyRing: TeleportKeyRing) throws {
        let payload = try encode(keyRing)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: keyRing.proxyHost),
        ]

        // Delete any existing item first (idempotent store).
        SecItemDelete(query as CFDictionary)

        var attributes: [String: Any] = query
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TeleportKeyRingStoreError.keychainError(status, "store")
        }
    }

    // MARK: - Retrieve

    func retrieve(proxyHost: String) throws -> TeleportKeyRing {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: proxyHost),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw TeleportKeyRingStoreError.decodeFailed
            }
            return try decode(data)
        case errSecItemNotFound:
            throw TeleportKeyRingStoreError.notFound
        default:
            throw TeleportKeyRingStoreError.keychainError(status, "retrieve")
        }
    }

    /// Retrieve the stored KeyRing if it exists and is still valid; nil otherwise.
    func currentValidKeyRing(proxyHost: String) -> TeleportKeyRing? {
        guard let keyRing = try? retrieve(proxyHost: proxyHost) else { return nil }
        return keyRing.isValid ? keyRing : nil
    }

    // MARK: - Delete

    func delete(proxyHost: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: proxyHost),
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Codable envelope

    private struct StoredKeyRing: Codable {
        let username: String
        let clusterName: String
        let proxyHost: String
        let sshPrivateKeyPEM: Data
        let sshPublicKeyAuthorized: String
        let sshCertificatePEM: String
        let tlsPrivateKeyPEM: Data
        let tlsPublicKeyPEM: String
        let tlsCertificatePEM: String
        let hostCheckingKeys: [String]
        let hostTLSCerts: [String]
        let expiryEpochSeconds: Double
    }

    private func encode(_ keyRing: TeleportKeyRing) throws -> Data {
        let stored = StoredKeyRing(
            username: keyRing.username,
            clusterName: keyRing.clusterName,
            proxyHost: keyRing.proxyHost,
            sshPrivateKeyPEM: keyRing.sshPrivateKeyPEM,
            sshPublicKeyAuthorized: keyRing.sshPublicKeyAuthorized,
            sshCertificatePEM: keyRing.sshCertificatePEM,
            tlsPrivateKeyPEM: keyRing.tlsPrivateKeyPEM,
            tlsPublicKeyPEM: keyRing.tlsPublicKeyPEM,
            tlsCertificatePEM: keyRing.tlsCertificatePEM,
            hostCheckingKeys: keyRing.hostCheckingKeys,
            hostTLSCerts: keyRing.hostTLSCerts,
            expiryEpochSeconds: keyRing.expiry.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        return try encoder.encode(stored)
    }

    private func decode(_ data: Data) throws -> TeleportKeyRing {
        let decoder = JSONDecoder()
        let stored = try decoder.decode(StoredKeyRing.self, from: data)
        return TeleportKeyRing(
            username: stored.username,
            clusterName: stored.clusterName,
            proxyHost: stored.proxyHost,
            sshPrivateKeyPEM: stored.sshPrivateKeyPEM,
            sshPublicKeyAuthorized: stored.sshPublicKeyAuthorized,
            sshCertificatePEM: stored.sshCertificatePEM,
            tlsPrivateKeyPEM: stored.tlsPrivateKeyPEM,
            tlsPublicKeyPEM: stored.tlsPublicKeyPEM,
            tlsCertificatePEM: stored.tlsCertificatePEM,
            hostCheckingKeys: stored.hostCheckingKeys,
            hostTLSCerts: stored.hostTLSCerts,
            expiry: Date(timeIntervalSince1970: stored.expiryEpochSeconds)
        )
    }
}
