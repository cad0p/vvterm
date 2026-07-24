// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  MockTeleportKeyRing.swift
//  VVTermUITests
//
//  A mock `TeleportKeyRingStoring` implementation for UI tests.
//
//  Scripts the per-cluster credential state so the readiness matrix
//  (mockup B) is fully assertable without a real keychain. The mock lets
//  each test fixture pre-seed a cluster with:
//    - a bootstrap cert (present/absent)
//    - a registered SEP key (present/absent)
//    - a cert expiry (valid/expired/none)
//
//  The readiness computation goes through the real
//  `TeleportDeviceReadinessResolver` (a pure function), so the mock's job is
//  just to return the right probe results for each cluster.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (mockup B —
//      the 5-row readiness matrix)
//    - VVTerm/Features/Teleport/Application/TeleportKeyRing.swift
//      (TeleportKeyRingStoring protocol + real impl)
//    - VVTerm/Features/Teleport/Domain/TeleportDeviceReadiness.swift
//      (TeleportDeviceReadinessResolver)
//

import Foundation
@testable import VVTerm

/// A mock Teleport key ring that scripts per-cluster credential state for
/// UI tests. Used by `TeleportReadinessUITests` to drive the 5-row readiness
/// matrix (ready / needsLogin / needsRegistration / needsBootstrap /
/// cross-device).
@MainActor
final class MockTeleportKeyRing: ObservableObject, TeleportKeyRingStoring {
    /// A scripted fixture for a single cluster's credential state.
    struct Fixture {
        /// Whether a bootstrap cert (PEM) is present.
        var hasBootstrapCert: Bool
        /// Whether a registered SEP key is present.
        var hasSEPKey: Bool
        /// The cert's ValidBefore, or nil if no cert.
        var certValidBefore: Date?
        /// The credential ID (for registeredCredentialID lookup).
        var credentialID: Data
        /// The user handle (for registeredUserHandle lookup).
        var userHandle: Data
        /// The device name.
        var deviceName: String
    }

    /// The per-cluster fixtures, keyed by cluster ID.
    private var fixtures: [UUID: Fixture] = [:]

    @Published private(set) var credentials: [UUID: TeleportCredential] = [:]

    /// Seed a cluster with a fixture. The fixture drives all the probe results.
    func seed(clusterId: UUID, fixture: Fixture) {
        fixtures[clusterId] = fixture
        // Build the TeleportCredential that matches (for the `credentials`
        // property + the registeredCredentialID/registeredUserHandle lookups).
        var cred = TeleportCredential(
            clusterId: clusterId,
            credentialID: fixture.credentialID.base64URLEncodedString(),
            userHandle: fixture.userHandle.base64URLEncodedString(),
            publicKeyRaw: "",
            deviceName: fixture.deviceName
        )
        if fixture.hasBootstrapCert {
            cred.sshCertPEM = "mock-bootstrap-cert-pem"
            cred.hasLiveCert = fixture.certValidBefore != nil
            cred.certValidBefore = fixture.certValidBefore ?? .distantPast
        }
        credentials[clusterId] = cred
    }

    // MARK: - TeleportKeyRingStoring

    func readiness(for clusterId: UUID) -> TeleportDeviceReadiness {
        // Drive the real resolver (pure function) with the fixture's probes.
        // This means the mock tests the resolver end-to-end, not a parallel
        // implementation.
        let fixture = fixtures[clusterId]
        let resolver = TeleportDeviceReadinessResolver(
            hasBootstrapCert: { _ in fixture?.hasBootstrapCert == true },
            hasSEPKey: { _ in fixture?.hasSEPKey == true },
            certExpiry: { _ in fixture?.certValidBefore }
        )
        return resolver.resolve(clusterId: clusterId)
    }

    func storeBootstrapCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        // Update the fixture so readiness reflects the new state.
        if var f = fixtures[clusterId] {
            f.hasBootstrapCert = true
            f.certValidBefore = validBefore
            fixtures[clusterId] = f
        }
    }

    func storeRegisteredSEPKey(
        credentialID: Data,
        userHandle: Data,
        publicKeyRaw: Data,
        deviceName: String,
        for clusterId: UUID
    ) {
        var cred = credentials[clusterId]
            ?? TeleportCredential(clusterId: clusterId, credentialID: "", userHandle: "", publicKeyRaw: "", deviceName: "")
        cred.credentialID = credentialID.base64URLEncodedString()
        cred.userHandle = userHandle.base64URLEncodedString()
        cred.publicKeyRaw = publicKeyRaw.base64URLEncodedString()
        cred.deviceName = deviceName
        credentials[clusterId] = cred
        if var f = fixtures[clusterId] {
            f.hasSEPKey = true
            f.credentialID = credentialID
            f.userHandle = userHandle
            f.deviceName = deviceName
            fixtures[clusterId] = f
        }
    }

    func storeLoginCert(_ certPEM: String, validBefore: Date, for clusterId: UUID) {
        guard var cred = credentials[clusterId] else { return }
        cred.sshCertPEM = certPEM
        cred.hasLiveCert = true
        cred.certValidBefore = validBefore
        credentials[clusterId] = cred
        if var f = fixtures[clusterId] {
            f.hasBootstrapCert = true  // a login cert implies bootstrap happened
            f.certValidBefore = validBefore
            fixtures[clusterId] = f
        }
    }

    func liveCertPEM(for clusterId: UUID) -> String? {
        guard let cred = credentials[clusterId], cred.isCertValid else { return nil }
        return cred.sshCertPEM
    }

    func registeredCredentialID(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.credentialID.isEmpty,
              let data = Data(base64URLEncoded: cred.credentialID) else {
            return nil
        }
        return data
    }

    func registeredUserHandle(for clusterId: UUID) -> Data? {
        guard let cred = credentials[clusterId],
              !cred.userHandle.isEmpty,
              let data = Data(base64URLEncoded: cred.userHandle) else {
            return nil
        }
        return data
    }

    // MARK: - ed25519 SSH private key (in-memory for the mock)

    /// The per-cluster ed25519 private key (OpenSSH PEM bytes). The real
    /// `TeleportKeyRing` stores this in the keychain; the mock keeps it
    /// in-memory so UI tests don't touch the keychain.
    private var ed25519PrivateKeys: [UUID: Data] = [:]

    func liveEd25519PrivateKey(for clusterId: UUID) -> Data? {
        ed25519PrivateKeys[clusterId]
    }

    func storeEd25519PrivateKey(_ pemData: Data, for clusterId: UUID) throws {
        ed25519PrivateKeys[clusterId] = pemData
    }

    func clear(for clusterId: UUID) {
        credentials.removeValue(forKey: clusterId)
        fixtures.removeValue(forKey: clusterId)
        ed25519PrivateKeys.removeValue(forKey: clusterId)
    }
}
