// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportCredentialStoreTests.swift
//  VVTermTests
//
//  Seam-contract coverage for `TeleportCredentialStore`:
//    - the host adapter shares state with the keyring it wraps (coordinators
//      and `SSHSession` must see the same object + in-memory state);
//    - the default adapter resolves the single host keyring;
//    - the movable keyring persists through an injected (suite-scoped)
//      `UserDefaults`, never `.standard`.
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

@MainActor
struct TeleportCredentialStoreTests {

    private func makeIsolatedKeyRing() -> TeleportKeyRing {
        let suiteName = "TeleportCredentialStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "app.vivy.vvterm.tests",
                defaults: defaults
            )
        )
    }

    @Test
    func adapterSharesStateWithTheInjectedKeyRing() async {
        let keyRing = makeIsolatedKeyRing()
        let store = TeleportKeyRingCredentialStore(keyRingProvider: { keyRing })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)

        await store.storeBootstrapCert("test-bootstrap-pem", validBefore: validBefore, for: clusterId)
        #expect(await store.liveCertPEM(for: clusterId) == "test-bootstrap-pem")
        // Same object: the direct keyring read (the UI's path) sees the
        // adapter's write.
        #expect(keyRing.liveCertPEM(for: clusterId) == "test-bootstrap-pem")

        let tlsState = TeleportClusterTLSState(
            clusterName: "ci-cluster",
            clusterCAPEMs: ["ca-pem"],
            hostCACheckingKeys: []
        )
        await store.storeClusterTLSState(tlsState, for: clusterId)
        #expect(await store.clusterTLSState(for: clusterId)?.clusterName == "ci-cluster")
        #expect(keyRing.clusterTLSState(for: clusterId)?.clusterName == "ci-cluster")

        // SEP-key metadata round-trip.
        await store.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "dev",
            for: clusterId
        )
        #expect(await store.registeredCredentialID(for: clusterId) == Data([1, 2, 3]))
        #expect(keyRing.registeredCredentialID(for: clusterId) == Data([1, 2, 3]))
        #expect(await store.registeredUserHandle(for: clusterId) == Data("handle".utf8))

        // Login cert overwrite + clear round-trip.
        await store.storeLoginCert("test-login-pem", validBefore: validBefore, for: clusterId)
        #expect(await store.liveCertPEM(for: clusterId) == "test-login-pem")
        await store.clear(for: clusterId)
        #expect(await store.liveCertPEM(for: clusterId) == nil)
        #expect(await store.clusterTLSState(for: clusterId) == nil)
    }

    @Test
    func defaultAdapterResolvesTheSingleHostKeyRing() async {
        // The production default must resolve `TeleportKeyRingHost.shared`,
        // so a coordinator write is visible to the UI and the SSH session.
        let store = TeleportKeyRingCredentialStore()
        let clusterId = UUID()
        await store.storeBootstrapCert(
            "host-roundtrip-pem",
            validBefore: Date().addingTimeInterval(3600),
            for: clusterId
        )
        defer { TeleportKeyRingHost.shared.clear(for: clusterId) }
        #expect(TeleportKeyRingHost.shared.liveCertPEM(for: clusterId) == "host-roundtrip-pem")
        #expect(await store.liveCertPEM(for: clusterId) == "host-roundtrip-pem")
    }
}
#endif
