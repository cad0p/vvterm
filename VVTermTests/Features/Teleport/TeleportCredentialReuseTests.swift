// SPDX-License-Identifier: MIT
//
//  TeleportCredentialReuseTests.swift
//  VVTermTests
//
//  Coverage for duplicate-server credential reuse:
//    - the pure matcher's `(host, username)` + cluster-name key and the
//      completeness gate (a deleted row's credential is never offered);
//    - the keyring's `isReusableRegistrationSource` precondition;
//    - `seedRegistration` copying the metadata + cluster TLS state but NOT the
//      cert (so the readiness resolver routes to `.needsLogin` and the picker
//      still shows).
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

struct TeleportCredentialReuseMatcherTests {

    private func makeServer(
        id: UUID = UUID(),
        name: String = "node",
        host: String = "teleport.example.com",
        username: String = "pier"
    ) -> Server {
        Server(
            id: id,
            workspaceId: UUID(),
            name: name,
            host: host,
            port: 443,
            username: username,
            authMethod: .faceIDTeleport
        )
    }

    private func makeCredential(clusterId: UUID, credentialID: String = "cred") -> TeleportCredential {
        TeleportCredential(
            clusterId: clusterId,
            credentialID: credentialID,
            userHandle: "handle",
            publicKeyRaw: "key",
            deviceName: "device"
        )
    }

    private func match(
        new: Server,
        live: [Server],
        credentials: [UUID: TeleportCredential],
        clusterNames: [UUID: String] = [:],
        isReusable: @escaping (UUID) -> Bool = { _ in true }
    ) -> Server? {
        TeleportCredentialReuse.match(
            newServer: new,
            liveServers: live,
            credentials: credentials,
            clusterName: { clusterNames[$0] },
            isReusable: isReusable
        )
    }

    @Test
    func matchesAHostAndUserDuplicate() {
        let source = makeServer(name: "source")
        let new = makeServer(name: "duplicate")
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)]
        )
        #expect(result?.id == source.id)
    }

    @Test
    func doesNotMatchItselfOrNonTeleportRows() {
        let new = makeServer()
        let passwordRow = Server(
            id: UUID(),
            workspaceId: UUID(),
            name: "password-row",
            host: new.host,
            username: new.username,
            authMethod: .password
        )
        let result = match(
            new: new,
            live: [new, passwordRow],
            credentials: [
                new.id: makeCredential(clusterId: new.id),
                passwordRow.id: makeCredential(clusterId: passwordRow.id)
            ]
        )
        #expect(result == nil)
    }

    @Test
    func doesNotMatchADifferentHostOrUser() {
        let otherHost = makeServer(host: "other.example.com")
        let otherUser = makeServer(username: "someone-else")
        let new = makeServer()
        let credentials: [UUID: TeleportCredential] = [
            otherHost.id: makeCredential(clusterId: otherHost.id),
            otherUser.id: makeCredential(clusterId: otherUser.id)
        ]
        #expect(match(new: new, live: [otherHost], credentials: credentials) == nil)
        #expect(match(new: new, live: [otherUser], credentials: credentials) == nil)
    }

    @Test
    func doesNotOfferADeletedRowsCredential() {
        // The source must be a LIVE server row: a credential left behind for a
        // deleted row (the record is cleared on delete, but a stale store
        // could persist one) is never offered.
        let deleted = makeServer()
        let new = makeServer()
        let result = match(
            new: new,
            live: [],  // the row is gone from ServerManager
            credentials: [deleted.id: makeCredential(clusterId: deleted.id)]
        )
        #expect(result == nil)
    }

    @Test
    func doesNotMatchWithoutACredentialRecord() {
        let source = makeServer()
        let new = makeServer()
        #expect(match(new: new, live: [source], credentials: [:]) == nil)
    }

    @Test
    func completenessGateIsHonored() {
        let source = makeServer()
        let new = makeServer()
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)],
            isReusable: { _ in false }
        )
        #expect(result == nil)
    }

    @Test
    func clusterNameMustMatchWhenTheNewRowKnowsIt() {
        let source = makeServer()
        let new = makeServer()
        let credentials = [source.id: makeCredential(clusterId: source.id)]

        // The new row has a cluster identity (a re-setup): the candidate must
        // belong to the same cluster.
        #expect(
            match(
                new: new,
                live: [source],
                credentials: credentials,
                clusterNames: [new.id: "cluster-b", source.id: "cluster-a"]
            ) == nil
        )
        #expect(
            match(
                new: new,
                live: [source],
                credentials: credentials,
                clusterNames: [new.id: "cluster-a", source.id: "cluster-a"]
            )?.id == source.id
        )
    }

    @Test
    func brandNewRowWithoutAClusterNameMatchesOnHostAndUser() {
        let source = makeServer()
        let new = makeServer()
        let result = match(
            new: new,
            live: [source],
            credentials: [source.id: makeCredential(clusterId: source.id)],
            clusterNames: [source.id: "cluster-a"]
        )
        #expect(result?.id == source.id)
    }

    @Test
    func firstSourceIsChosenDeterministically() {
        let beta = makeServer(name: "beta")
        let alpha = makeServer(name: "alpha")
        let new = makeServer()
        let result = match(
            new: new,
            live: [beta, alpha],
            credentials: [
                beta.id: makeCredential(clusterId: beta.id),
                alpha.id: makeCredential(clusterId: alpha.id)
            ]
        )
        #expect(result?.id == alpha.id, "sources are ordered by display name")
    }
}

@MainActor
struct TeleportKeyRingReuseTests {

    private func makeIsolatedKeyRing() -> (TeleportKeyRing, MockSEPKeySigner) {
        let suiteName = "TeleportKeyRingReuseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let signer = MockSEPKeySigner(outcome: .success)
        let keyRing = TeleportKeyRing(
            signer: signer,
            logging: DefaultTeleportLogging(),
            config: TeleportKeychainConfig(
                keychainService: "app.vivy.vvterm.tests",
                defaults: defaults
            )
        )
        return (keyRing, signer)
    }

    private func seedCompleteSetup(
        keyRing: TeleportKeyRing,
        signer: MockSEPKeySigner,
        clusterId: UUID,
        credentialID: Data = Data([1, 2, 3, 4]),
        clusterName: String = "ci-cluster",
        checkingKeys: [String] = ["ssh-ed25519 AAAA host-ca"]
    ) throws {
        keyRing.storeRegisteredSEPKey(
            credentialID: credentialID,
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "device",
            for: clusterId
        )
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: clusterName,
                clusterCAPEMs: ["ca-pem"],
                hostCACheckingKeys: checkingKeys
            ),
            for: clusterId
        )
        _ = try signer.createKey(credentialID: credentialID)
    }

    @Test
    func reusableOnlyForACompleteLiveRegistration() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let id = UUID()

        // No record at all.
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: nil))

        // Record but no SEP key.
        let (noKeyRing, _) = makeIsolatedKeyRing()
        noKeyRing.storeRegisteredSEPKey(
            credentialID: Data([1, 2, 3, 4]),
            userHandle: Data("handle".utf8),
            publicKeyRaw: Data([9]),
            deviceName: "device",
            for: id
        )
        noKeyRing.storeClusterTLSState(
            TeleportClusterTLSState(clusterName: "ci-cluster", clusterCAPEMs: ["ca"], hostCACheckingKeys: ["k"]),
            for: id
        )
        #expect(!noKeyRing.isReusableRegistrationSource(for: id, clusterName: nil))

        // Complete setup.
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: id)
        #expect(keyRing.isReusableRegistrationSource(for: id, clusterName: nil))
        #expect(keyRing.isReusableRegistrationSource(for: id, clusterName: "ci-cluster"))
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: "other-cluster"))
    }

    @Test
    func legacySetupWithNoCheckingKeysIsNotReusable() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let id = UUID()
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: id, checkingKeys: [])
        #expect(!keyRing.isReusableRegistrationSource(for: id, clusterName: nil))
    }

    @Test
    func seedingCopiesMetadataAndTLSStateButNotTheCert() throws {
        let (keyRing, signer) = makeIsolatedKeyRing()
        let sourceId = UUID()
        let targetId = UUID()
        let credentialID = Data([7, 7, 7, 7])
        try seedCompleteSetup(keyRing: keyRing, signer: signer, clusterId: sourceId, credentialID: credentialID)
        let validBefore = Date().addingTimeInterval(3600)
        keyRing.storeLoginCert("source-cert-pem", validBefore: validBefore, for: sourceId)
        try keyRing.storeEd25519PrivateKey(Data("key".utf8), for: sourceId)

        #expect(keyRing.seedRegistration(from: sourceId, to: targetId))

        let seeded = try #require(keyRing.credentials[targetId])
        #expect(seeded.credentialID == keyRing.credentials[sourceId]?.credentialID)
        #expect(seeded.userHandle == keyRing.credentials[sourceId]?.userHandle)
        #expect(seeded.publicKeyRaw == keyRing.credentials[sourceId]?.publicKeyRaw)
        #expect(seeded.deviceName == keyRing.credentials[sourceId]?.deviceName)
        #expect(seeded.sshCertPEM == nil, "the certificate must not be copied")
        #expect(seeded.hasLiveCert == false)
        #expect(keyRing.clusterTLSState(for: targetId)?.clusterName == "ci-cluster")
        #expect(keyRing.liveEd25519PrivateKey(for: targetId) == nil, "the ed25519 key must not be copied")

        // The whole point: the seeded row needs the Face ID login (and shows
        // the picker), not a connect.
        #expect(keyRing.readiness(for: targetId) == .needsLogin)
    }

    @Test
    func seedingRefusesIncompleteSources() {
        let (keyRing, _) = makeIsolatedKeyRing()
        let sourceId = UUID()
        let targetId = UUID()
        #expect(!keyRing.seedRegistration(from: sourceId, to: targetId))
        #expect(!keyRing.seedRegistration(from: targetId, to: targetId))
    }
}
#endif
