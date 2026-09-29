// SPDX-License-Identifier: MIT
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
import Security
import Testing
@testable import VVTerm

@MainActor
struct TeleportCredentialStoreTests {

    private func makeIsolatedKeyRing(
        keychainWriter: TeleportKeyRing.Ed25519KeychainWriter? = nil
    ) -> TeleportKeyRing {
        let suiteName = "TeleportCredentialStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        return TeleportKeyRing(
            signer: MockSEPKeySigner(outcome: .success),
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "app.vivy.vvterm.tests",
                defaults: defaults
            ),
            keychainWriter: keychainWriter
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
        // Identity-only assertion: this test must not mutate production
        // state (the write→read round-trip above uses a suite-scoped
        // keyring).
        let store = TeleportKeyRingCredentialStore()
        #expect(store.resolvedKeyRing === TeleportKeyRingHost.shared)
    }

    // MARK: - T5: the pair write round-trip and the policy semantics

    /// T5: `.bootstrap` creates the record when absent — through the adapter,
    /// on the real keyring — and both halves land (not merely "did not
    /// throw").
    @Test
    func bootstrapPairWriteCreatesTheRecordThroughTheAdapter() async throws {
        let keyRing = makeIsolatedKeyRing()
        let store = TeleportKeyRingCredentialStore(keyRingProvider: { keyRing })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        let key = Data("pair-round-trip-key".utf8)

        try await store.storeCredentialPair(
            "pair-round-trip-cert",
            validBefore: validBefore,
            privateKeyPEM: key,
            policy: .bootstrap,
            for: clusterId
        )

        let snapshot = await store.liveCredentialSnapshot(for: clusterId)
        #expect(snapshot?.certPEM == "pair-round-trip-cert")
        #expect(snapshot?.privateKeyPEM == key)
        #expect(keyRing.credentials[clusterId] != nil, "the bootstrap policy created the record")
        keyRing.clear(for: clusterId)
    }

    /// T5: `.login` with no record and a seeded prior key throws
    /// `noRegisteredCredential` before any write — the prior key survives and
    /// no record is created (the no-orphan-key pin).
    @Test
    func loginPairWithoutARecordWritesNeitherHalf() async throws {
        let keyRing = makeIsolatedKeyRing()
        let store = TeleportKeyRingCredentialStore(keyRingProvider: { keyRing })
        let clusterId = UUID()
        let priorKey = Data("seeded-prior-key".utf8)
        try keyRing.storeEd25519PrivateKey(priorKey, for: clusterId)
        #expect(keyRing.liveEd25519PrivateKey(for: clusterId) == priorKey)

        await #expect(throws: TeleportCredentialStoreError.noRegisteredCredential(clusterId: clusterId)) {
            try await store.storeCredentialPair(
                "orphan-cert-pem",
                validBefore: Date().addingTimeInterval(3600),
                privateKeyPEM: Data("orphan-key".utf8),
                policy: .login,
                for: clusterId
            )
        }

        #expect(
            keyRing.liveEd25519PrivateKey(for: clusterId) == priorKey,
            "the no-record .login pair must not write the orphan key"
        )
        #expect(await store.liveCertPEM(for: clusterId) == nil)
        #expect(keyRing.credentials[clusterId] == nil, "no record was created")
        keyRing.clear(for: clusterId)
    }

    /// T5: a second `.bootstrap` pair write preserves the registered SEP
    /// metadata (credentialID / userHandle / publicKeyRaw / deviceName) — the
    /// commit mutates the cert fields only.
    @Test
    func secondBootstrapPairWritePreservesTheSEPMetadata() async throws {
        let keyRing = makeIsolatedKeyRing()
        let store = TeleportKeyRingCredentialStore(keyRingProvider: { keyRing })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)

        await store.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3, 4]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9, 9]),
            deviceName: "device-A",
            for: clusterId
        )
        try await store.storeCredentialPair(
            "first-cert",
            validBefore: validBefore,
            privateKeyPEM: Data("first-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )
        try await store.storeCredentialPair(
            "second-cert",
            validBefore: validBefore,
            privateKeyPEM: Data("second-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )

        #expect(await store.registeredCredentialID(for: clusterId) == Data([1, 2, 3, 4]))
        #expect(await store.registeredUserHandle(for: clusterId) == Data("handle".utf8))
        #expect(keyRing.credentials[clusterId]?.publicKeyRaw == Data([9, 9]).base64URLEncodedString())
        #expect(keyRing.credentials[clusterId]?.deviceName == "device-A")
        #expect(keyRing.credentials[clusterId]?.sshCertPEM == "second-cert")
        #expect(keyRing.liveEd25519PrivateKey(for: clusterId) == Data("second-key".utf8))
        keyRing.clear(for: clusterId)
    }

    /// T5: the UI-test mock's readiness flips after a pair write (its fixture
    /// is kept coherent, same as the single writes).
    @Test
    func mockReadinessFlipsAfterAPairWrite() async throws {
        let mock = MockTeleportKeyRing()
        let clusterId = UUID()
        mock.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: false,
                hasSEPKey: true,
                certValidBefore: nil,
                credentialID: Data([1, 2, 3]),
                userHandle: Data("handle".utf8),
                deviceName: "test-device"
            )
        )
        #expect(mock.readiness(for: clusterId) == .needsLogin)

        try mock.storeCredentialPair(
            "mock-pair-cert",
            validBefore: TeleportFixtureSupport.attemptCertValidBefore,
            privateKeyPEM: Data("mock-pair-key".utf8),
            policy: .bootstrap,
            for: clusterId
        )

        #expect(mock.readiness(for: clusterId) == .ready)
        #expect(mock.liveCredentialSnapshot(for: clusterId)?.certPEM == "mock-pair-cert")
    }

    // MARK: - T4: the keychain-write seam and the non-destructive direction

    /// T4: a scripted keychain *update* failure throws the pair write and
    /// commits neither half; the prior record and the prior key survive
    /// (nothing was deleted). Uses a seeded prior pair so the assertion is
    /// discriminating.
    @Test
    func pairWriteUpdateFailureLeavesThePriorRecordAndKeyIntact() async throws {
        let writer = ScriptedEd25519KeychainWriter()
        writer.item = Data("prior-key".utf8)
        let keyRing = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeBootstrapCert("prior-cert-pem", validBefore: validBefore, for: clusterId)
        writer.script = .updateFails(errSecAuthFailed)

        #expect(throws: TeleportPackageError.keychain(errSecAuthFailed)) {
            try keyRing.storeCredentialPair(
                "new-cert-pem",
                validBefore: validBefore,
                privateKeyPEM: Data("new-key".utf8),
                policy: .bootstrap,
                for: clusterId
            )
        }

        #expect(writer.updateCount == 1, "the pair write reached the keychain seam")
        #expect(writer.addCount == 0)
        #expect(writer.item == Data("prior-key".utf8), "the failed update must not destroy the prior key")
        #expect(keyRing.liveCertPEM(for: clusterId) == "prior-cert-pem", "the record was not committed")
    }

    /// T4: a scripted `errSecItemNotFound` update followed by a failing add
    /// throws the pair write; the prior record is unchanged and no key is
    /// committed (the failed add never deletes).
    @Test
    func pairWriteAddFailureLeavesThePriorRecordIntactAndCommitsNoKey() async throws {
        let writer = ScriptedEd25519KeychainWriter()
        let keyRing = makeIsolatedKeyRing(keychainWriter: { try writer.write($0, clusterId: $1) })
        let clusterId = UUID()
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeBootstrapCert("prior-cert-pem", validBefore: validBefore, for: clusterId)
        writer.script = .addFails(errSecAuthFailed)

        #expect(throws: TeleportPackageError.keychain(errSecAuthFailed)) {
            try keyRing.storeCredentialPair(
                "new-cert-pem",
                validBefore: validBefore,
                privateKeyPEM: Data("new-key".utf8),
                policy: .bootstrap,
                for: clusterId
            )
        }

        #expect(writer.updateCount == 1)
        #expect(writer.addCount == 1)
        #expect(writer.item == nil, "the failed add must not commit a key")
        #expect(keyRing.liveCertPEM(for: clusterId) == "prior-cert-pem", "the record was not committed")
        #expect(keyRing.liveEd25519PrivateKey(for: clusterId) == nil)
    }
}

/// An in-memory keychain-write model for the injectable `TeleportKeyRing`
/// seam. It mirrors the production update-first, non-destructive direction: a
/// scripted update failure throws without touching the item; a scripted add
/// failure throws without deleting.
@MainActor
private final class ScriptedEd25519KeychainWriter {
    enum Script {
        case real
        case updateFails(OSStatus)
        case addFails(OSStatus)
    }

    var item: Data?
    var script: Script = .real
    private(set) var updateCount = 0
    private(set) var addCount = 0

    func write(_ pemData: Data, clusterId: UUID) throws {
        switch script {
        case .real:
            updateCount += 1
            if item == nil {
                addCount += 1
            }
            item = pemData
        case .updateFails(let status):
            updateCount += 1
            throw TeleportPackageError.keychain(status)
        case .addFails(let status):
            updateCount += 1
            addCount += 1
            throw TeleportPackageError.keychain(status)
        }
    }
}
#endif
