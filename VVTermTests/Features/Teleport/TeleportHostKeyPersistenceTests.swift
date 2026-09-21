// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportHostKeyPersistenceTests.swift
//  VVTermTests
//
//  Coverage for the Host CA checking-key persistence:
//    - `checking_keys` wire decoding is base64(authorized_keys line), not
//      base64(PEM);
//    - legacy persisted `TeleportClusterTLSState` payloads decode with an
//      empty checking-key list instead of dropping the whole map;
//    - the additions-only refresh rule (superset accepted; a refresh that
//      would drop a pinned key is rejected).
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

struct TeleportHostKeyPersistenceTests {

    private static let hostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let otherHostCA = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_foreign.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    // MARK: - Wire decoding

    @Test
    func hostSignerDecodesBase64AuthorizedKeysLines() throws {
        let json = """
        {
          "domain_name": "teleport.pcad.it",
          "checking_keys": [
            "\(Data(Self.hostCA.utf8).base64EncodedString())",
            "%%%not-base64%%%"
          ]
        }
        """
        let signer = try JSONDecoder().decode(
            LoginFinishResponse.HostSigner.self,
            from: Data(json.utf8)
        )
        #expect(signer.domainName == "teleport.pcad.it")
        #expect(signer.checkingKeys == [Self.hostCA])
    }

    @Test
    func decoderTreatsBase64PEMAsGarbage() {
        // A base64(PEM) element (the old, wrong decoding) is not an
        // authorized_keys line and must be dropped rather than stored.
        let pem = "-----BEGIN CERTIFICATE-----\nZmFrZQ==\n-----END CERTIFICATE-----"
        let decoded = TeleportHostCACheckingKeysDecoder.decode(Data(pem.utf8).base64EncodedString())
        #expect(decoded != nil)  // decoding succeeds...
        // ...but normalization to key blobs drops it.
        #expect(TeleportHostCACheckingKeysDecoder.normalizedLines([decoded ?? ""]).isEmpty)
    }

    // MARK: - Persistence round-trip

    @Test
    func legacyStateDecodesWithEmptyCheckingKeys() throws {
        let legacy = #"{"clusterName":"teleport.pcad.it","clusterCAPEMs":["-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----"]}"#
        let state = try JSONDecoder().decode(TeleportClusterTLSState.self, from: Data(legacy.utf8))
        #expect(state.clusterName == "teleport.pcad.it")
        #expect(state.hostCACheckingKeys.isEmpty)
    }

    @Test
    func stateRoundTripsIncludingCheckingKeys() throws {
        let state = TeleportClusterTLSState(
            clusterName: "teleport.pcad.it",
            clusterCAPEMs: ["pem-1"],
            hostCACheckingKeys: [Self.hostCA]
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TeleportClusterTLSState.self, from: data)
        #expect(decoded == state)
    }

    // MARK: - Additions-only refresh rule

    @Test
    func supersetRefreshIsAccepted() {
        let state = TeleportClusterTLSState(
            clusterName: "c",
            clusterCAPEMs: ["pem"],
            hostCACheckingKeys: [Self.hostCA]
        )
        let outcome = TeleportHostKeyUpdatePolicy.apply(
            checkingKeys: [Self.hostCA, Self.otherHostCA],
            to: state
        )
        #expect(outcome.result == .updated)
        #expect(outcome.updatedState?.hostCACheckingKeys.count == 2)
        #expect(outcome.updatedState?.clusterName == "c")
        #expect(outcome.updatedState?.clusterCAPEMs == ["pem"])
    }

    @Test
    func refreshThatDropsAPinnedKeyIsRejected() {
        let state = TeleportClusterTLSState(
            clusterName: "c",
            clusterCAPEMs: ["pem"],
            hostCACheckingKeys: [Self.hostCA]
        )
        let outcome = TeleportHostKeyUpdatePolicy.apply(
            checkingKeys: [Self.otherHostCA],
            to: state
        )
        #expect(outcome.result == .rejectedWouldDropPinnedKeys)
        #expect(outcome.updatedState == nil)
    }

    @Test
    func identicalRefreshIsANoOp() {
        let state = TeleportClusterTLSState(
            clusterName: "c",
            clusterCAPEMs: ["pem"],
            hostCACheckingKeys: [Self.hostCA]
        )
        let outcome = TeleportHostKeyUpdatePolicy.apply(checkingKeys: [Self.hostCA], to: state)
        #expect(outcome.result == .noChange)
        #expect(outcome.updatedState == nil)
    }

    @Test
    func commentOnlyChangeIsANoOp() {
        // The same key blob with a different comment must not be treated as
        // a new anchor.
        let state = TeleportClusterTLSState(
            clusterName: "c",
            clusterCAPEMs: ["pem"],
            hostCACheckingKeys: [Self.hostCA]
        )
        let outcome = TeleportHostKeyUpdatePolicy.apply(
            checkingKeys: [Self.hostCA + " different-comment"],
            to: state
        )
        #expect(outcome.result == .noChange)
    }

    @Test
    func emptyOrGarbageRefreshIsANoOp() {
        let state = TeleportClusterTLSState(
            clusterName: "c",
            clusterCAPEMs: ["pem"],
            hostCACheckingKeys: [Self.hostCA]
        )
        #expect(TeleportHostKeyUpdatePolicy.apply(checkingKeys: [], to: state).result == .noChange)
        #expect(TeleportHostKeyUpdatePolicy.apply(checkingKeys: ["garbage"], to: state).result == .noChange)
    }

    // MARK: - Mock keyring conformance

    @MainActor
    @Test
    func mockKeyRingAppliesAndRejectsRefreshes() {
        let keyRing = MockTeleportKeyRing()
        let clusterId = UUID()
        keyRing.storeClusterTLSState(
            TeleportClusterTLSState(
                clusterName: "c",
                clusterCAPEMs: ["pem"],
                hostCACheckingKeys: [Self.hostCA]
            ),
            for: clusterId
        )

        #expect(keyRing.updateClusterHostKeys([Self.hostCA, Self.otherHostCA], for: clusterId) == .updated)
        #expect(keyRing.clusterTLSState(for: clusterId)?.hostCACheckingKeys.count == 2)

        #expect(keyRing.updateClusterHostKeys([Self.hostCA], for: clusterId) == .rejectedWouldDropPinnedKeys)
        #expect(keyRing.clusterTLSState(for: clusterId)?.hostCACheckingKeys.count == 2)
    }
}

#endif
