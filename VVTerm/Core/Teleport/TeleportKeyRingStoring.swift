// SPDX-License-Identifier: MIT
//
//  TeleportKeyRingStoring.swift
//  VVTerm
//
//  The host-side observation protocol for the Teleport keyring.
//
//  `TeleportKeyRingStoring` is `@MainActor` + `ObservableObject` because the
//  UI observes the keyring with `@ObservedObject` (the readiness pill on the
//  server row recomputes when credentials change). It therefore cannot move
//  into the package: the movable keyring conforms to the plain `Sendable`
//  `TeleportCredentialStore` seam instead, and this host-side extension
//  declares the observation conformance.
//

import Combine
import Foundation

/// Protocol-backed so UI tests can inject a `MockTeleportKeyRing` (e.g. to
/// script the `needsLogin` ↔ `ready` flip without a real keychain). The
/// `Live` impl is the `TeleportKeyRing` class.
@MainActor
protocol TeleportKeyRingStoring: AnyObject, ObservableObject {
    /// All known credentials, keyed by cluster ID.
    var credentials: [UUID: TeleportCredential] { get }

    /// Compute the derived readiness state for a cluster (no network).
    func readiness(for clusterId: UUID) -> TeleportDeviceReadiness

    /// Store a Phase-1 bootstrap cert (pre-registration). The cert is valid
    /// for a short window; `hasLiveCert` is set so readiness flips to
    /// `needsRegistration` (not `needsBootstrap`).
    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID)

    /// Store the SEP key metadata captured at Phase 2 registration. The SEP
    /// key itself is already in the Secure Enclave (created by
    /// `SecureEnclaveSigner.createKey`); this records the lookup metadata.
    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    )

    /// Store a Phase-3 login cert (post-registration). Overwrites any prior
    /// cert; `hasLiveCert` is set so readiness flips to `ready`.
    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID)

    /// The live cert PEM for a cluster, or nil if no valid cert.
    func liveCertPEM(for clusterId: UUID) -> String?

    /// The registered SEP key's credentialID for a cluster, or nil if not
    /// registered. Used by the login coordinator to load the SEP key.
    func registeredCredentialID(for clusterId: UUID) -> Data?

    /// The registered userHandle for a cluster (UTF-8 bytes), or nil.
    /// Required by the server's passwordless login verify path.
    func registeredUserHandle(for clusterId: UUID) -> Data?

    /// The cluster name (from host_signers[0].domain_name) + cluster TLS CA
    /// certs (from host_signers[0].tls_certs) captured at Phase 1 bootstrap.
    /// Required by the SSH TLS+ALPN transport (`SSHTLSTransport`) to verify
    /// the Teleport proxy's TLS cert when dialing SSH on port 443 (TLS
    /// Routing, ALPN `teleport-proxy-ssh`).
    func clusterTLSState(for clusterId: UUID) -> TeleportClusterTLSState?

    /// Store the cluster name + TLS CA certs for a cluster.
    func storeClusterTLSState(_ state: TeleportClusterTLSState, for clusterId: UUID)

    /// Refresh the Host CA checking keys captured for a cluster.
    ///
    /// Additions-only: a refresh that would drop a currently pinned key is
    /// rejected (the pinned anchors are kept) because the login/finish
    /// channel is not authenticated for anchor rotation.
    func updateClusterHostKeys(_ checkingKeys: [String], for clusterId: UUID) -> TeleportHostKeyUpdateResult

    /// The ed25519 private key (OpenSSH PEM format) paired with the live
    /// cert, or nil if none.
    func liveEd25519PrivateKey(for clusterId: UUID) -> Data?

    /// Store the ed25519 private key (OpenSSH PEM bytes) for a cluster.
    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) throws

    /// Clear all credential state for a cluster (metadata only — the SEP key
    /// itself is removed via `SecureEnclaveSigner.deleteKey`).
    func clear(for clusterId: UUID)
}

/// The movable keyring implements every requirement; this host-side
/// extension is where the observation conformance is declared so the movable
/// file never names `TeleportKeyRingStoring`.
extension TeleportKeyRing: TeleportKeyRingStoring {}
