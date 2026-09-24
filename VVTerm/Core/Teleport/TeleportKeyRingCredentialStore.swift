// SPDX-License-Identifier: MIT
//
//  TeleportKeyRingCredentialStore.swift
//  VVTerm
//
//  The host-side `TeleportCredentialStore` adapter over the `@MainActor`
//  `TeleportKeyRing`.
//
//  `SSHSession` is an actor and must not hop onto the main actor; this
//  adapter is `nonisolated` + `@unchecked Sendable` and performs exactly one
//  MainActor hop per operation, with a single synchronous MainActor body and
//  no internal suspension — so each keyring operation keeps today's
//  atomicity.
//
//  The keyring is resolved lazily on the main actor so the adapter can be
//  constructed from any isolation domain (it is the defaulted
//  `SSHClient.teleportCredentialStore` value, and `SSHClient()` is created
//  from both main-actor and background contexts). Production resolves the
//  single host provider (`TeleportKeyRingHost.shared`); tests inject a
//  specific keyring to prove identity + state sharing.
//

import Foundation

final class TeleportKeyRingCredentialStore: TeleportCredentialStore, @unchecked Sendable {
    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}
    /// Resolves the keyring on the main actor. Defaults to the single host
    /// provider.
    private let keyRingProvider: @MainActor @Sendable () -> TeleportKeyRing

    init(
        keyRingProvider: @escaping @MainActor @Sendable () -> TeleportKeyRing = { TeleportKeyRingHost.shared }
    ) {
        self.keyRingProvider = keyRingProvider
    }

    /// The keyring this adapter resolves, on the main actor. Exposed so the
    /// seam test can assert the production default resolves the single host
    /// instance without mutating production state.
    @MainActor
    var resolvedKeyRing: TeleportKeyRing { keyRingProvider() }

    // MARK: - Reads

    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState? {
        await MainActor.run { keyRingProvider().clusterTLSState(for: clusterId) }
    }

    func liveCertPEM(for clusterId: UUID) async -> String? {
        await MainActor.run { keyRingProvider().liveCertPEM(for: clusterId) }
    }

    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().liveEd25519PrivateKey(for: clusterId) }
    }

    func registeredCredentialID(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().registeredCredentialID(for: clusterId) }
    }

    func registeredUserHandle(for clusterId: UUID) async -> Data? {
        await MainActor.run { keyRingProvider().registeredUserHandle(for: clusterId) }
    }

    // MARK: - Writes

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeBootstrapCert(certPEM, validBefore: validBefore, for: clusterId)
        }
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) async {
        await MainActor.run {
            keyRingProvider().storeRegisteredSEPKey(
                credentialID: credentialID,
                userHandle: userHandle,
                publicKeyRaw: publicKeyRaw,
                deviceName: deviceName,
                for: clusterId
            )
        }
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeLoginCert(certPEM, validBefore: validBefore, for: clusterId)
        }
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws {
        try await MainActor.run {
            try keyRingProvider().storeEd25519PrivateKey(pemData, for: clusterId)
        }
    }

    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().storeClusterTLSState(state, for: clusterId)
        }
    }

    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult {
        await MainActor.run {
            keyRingProvider().updateClusterHostKeys(checkingKeys, for: clusterId)
        }
    }

    func clear(for clusterId: UUID) async {
        await MainActor.run {
            keyRingProvider().clear(for: clusterId)
        }
    }
}
