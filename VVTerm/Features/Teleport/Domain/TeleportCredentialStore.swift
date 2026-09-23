// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportCredentialStore.swift
//  VVTerm
//
//  The package-movable credential store seam for the Teleport feature.
//
//  This protocol covers the union of keyring operations used outside
//  `Features/Teleport/UI`: the coordinators' writes (bootstrap/login/
//  registration) and `SSHSession`'s reads (cluster TLS state, live cert,
//  ed25519 private key). The host-side `TeleportKeyRing` conforms to it
//  directly, and a host adapter (`TeleportKeyRingCredentialStore`) exposes
//  it as the default `SSHClient` store with one MainActor hop per operation.
//
//  All methods are `async` + the protocol is `Sendable`, so the package can
//  be built in Swift 6 mode and the store can be called from `SSHSession`'s
//  actor without hopping the session onto the main actor.
//

import Foundation

protocol TeleportCredentialStore: Sendable {
    // MARK: - Reads

    /// The cluster name + TLS CA certs captured at Phase 1 bootstrap.
    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState?

    /// The live cert PEM for a cluster, or nil if no valid cert.
    func liveCertPEM(for clusterId: UUID) async -> String?

    /// The ed25519 private key (OpenSSH PEM format) paired with the live
    /// cert, or nil if none.
    func liveEd25519PrivateKey(for clusterId: UUID) async -> Data?

    /// The registered SEP key's credentialID for a cluster, or nil.
    func registeredCredentialID(for clusterId: UUID) async -> Data?

    /// The registered userHandle for a cluster, or nil.
    func registeredUserHandle(for clusterId: UUID) async -> Data?

    // MARK: - Writes

    /// Store a Phase-1 bootstrap cert (pre-registration).
    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async

    /// Store the SEP key metadata captured at Phase 2 registration.
    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) async

    /// Store a Phase-3 login cert (post-registration).
    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) async

    /// Store the ed25519 private key (OpenSSH PEM bytes) for a cluster.
    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws

    /// Store the cluster name + TLS CA certs for a cluster.
    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async

    /// Refresh the Host CA checking keys captured for a cluster.
    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult

    /// Clear all credential state for a cluster.
    func clear(for clusterId: UUID) async
}
