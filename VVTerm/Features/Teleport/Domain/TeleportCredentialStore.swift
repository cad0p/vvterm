// SPDX-License-Identifier: MIT
//
//  TeleportCredentialStore.swift
//  VVTerm
//
//  The package-movable credential store seam for the Teleport feature.
//
//  This protocol covers the union of keyring operations used outside
//  `Features/Teleport/UI`: the coordinators' writes (bootstrap/login/
//  registration) and `SSHSession`'s reads (cluster TLS state, live cert +
//  key snapshot, ed25519 private key).
//
//  Conformers (all four named per the #262 plan review):
//    - `TeleportKeyRing` (production, also the observation source);
//    - `TeleportKeyRingCredentialStore` (the host adapter the `SSHClient`
//      default store uses);
//    - `MockTeleportKeyRing` (DEBUG UI-test/harness);
//    - `GatedTeleportCredentialStore` (test suite, coordinator races).
//
//  All methods are `async` + the protocol is `Sendable`, so the package can
//  be built in Swift 6 mode and the store can be called from `SSHSession`'s
//  actor without hopping the session onto the main actor.
//

import Foundation

/// Which cert-store policy the atomic pair write applies.
///
/// `.bootstrap` mutates the cert fields of an existing record, creating the
/// record only when it is absent (preserving the registered SEP metadata).
/// `.login` requires an existing record.
enum TeleportCredentialWritePolicy: Sendable {
    case bootstrap
    case login
}

/// A pair write could not proceed without leaving a torn credential.
enum TeleportCredentialStoreError: Error, Equatable, LocalizedError {
    /// `.login` was requested for a cluster with no credential record.
    case noRegisteredCredential(clusterId: UUID)

    /// The user-facing text: no cluster UUID (the payload keeps it for logs).
    /// The coordinators use this as the D3 terminal message so the
    /// concurrent-clear case is distinguishable from a keychain failure.
    var errorDescription: String? {
        switch self {
        case .noRegisteredCredential:
            return "the registered credential was cleared while the flow was in progress"
        }
    }
}

protocol TeleportCredentialStore: Sendable {
    // MARK: - Reads

    /// The cluster name + TLS CA certs captured at Phase 1 bootstrap.
    func clusterTLSState(for clusterId: UUID) async -> TeleportClusterTLSState?

    /// The live cert PEM for a cluster, or nil if no valid cert.
    func liveCertPEM(for clusterId: UUID) async -> String?

    /// The live cert PEM **and** its paired ed25519 private key read together,
    /// or nil when either is missing.
    ///
    /// The connect path resolves the SSH username against the *exact* PEM it
    /// sends, so it must read the cert + key as one pair: two separate reads
    /// could observe a fresh cert with a stale key after a concurrent re-login.
    func liveCredentialSnapshot(for clusterId: UUID) async -> (certPEM: String, privateKeyPEM: Data)?

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
    ///
    /// A non-atomic seed/test primitive: it writes the key alone, so a caller
    /// that needs the cert + key to land as one unit must use
    /// `storeCredentialPair` instead. No coordinator calls it.
    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) async throws

    /// Write a cert and its paired ed25519 private key as one indivisible unit.
    ///
    /// The key write and the credential-record commit land in one
    /// non-suspending `@MainActor` body, so no other actor code can interleave
    /// between them: a superseded attempt lands a complete, self-consistent
    /// credential, or the previous complete credential is left intact, or
    /// nothing is committed — never a mixed pair.
    ///
    /// Scope: interleaving atomicity within one process, not crash durability.
    /// The record lives in `UserDefaults` and the key in the Keychain; the two
    /// backends share no transaction, so a crash between the writes can still
    /// leave a genuinely mixed pair — `liveCredentialSnapshot` returns non-nil
    /// for it and only the server's signature check rejects it. Atomicity is
    /// also per keyring instance: a second `TeleportKeyRing` over the same
    /// defaults/keychain could tear against the first (one instance per process
    /// today, `TeleportKeyRingHost.shared`).
    ///
    /// The non-suspending body excludes task interleaving but not synchronous
    /// re-entrancy through `@Published`'s `willSet` at the record commit; no
    /// subscriber re-enters the store today (SwiftUI schedules its updates).
    ///
    /// The single writes (`storeBootstrapCert` / `storeLoginCert` /
    /// `storeEd25519PrivateKey`) remain on this protocol as the seed/test
    /// primitives and the two-call tear counterfactual; they are not atomic.
    ///
    /// - Parameter policy: `.bootstrap` mutates the cert fields of the existing
    ///   record, creating the record only when it is absent (preserving the SEP
    ///   metadata). `.login` requires an existing record and throws
    ///   `TeleportCredentialStoreError.noRegisteredCredential` without writing
    ///   either half when it is missing.
    func storeCredentialPair(
        _ certPEM: String,
        validBefore: Date,
        privateKeyPEM: Data,
        policy: TeleportCredentialWritePolicy,
        for clusterId: UUID
    ) async throws

    /// Store the cluster name + TLS CA certs for a cluster.
    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID) async

    /// Refresh the Host CA checking keys captured for a cluster.
    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) async -> TeleportHostKeyUpdateResult

    /// Clear all credential state for a cluster.
    func clear(for clusterId: UUID) async
}
