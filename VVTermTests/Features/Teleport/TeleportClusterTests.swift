// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportClusterTests.swift
//  VVTermTests
//
//  Layer 1 unit tests for `TeleportCluster.sepKeyLabel`.
//
//  The label format `vvterm/<cluster>:<user>` is the SEP keychain key-isolation
//  scheme (matches tsh's per-cluster key isolation). This file asserts the
//  format is correct for multiple clusters and that two different clusters
//  (or two different users on the same cluster) don't collide.
//
//  See:
//    - 2026-07-23-strategy-b-session2.2-teleport-ui-design.md (CI strategy
//      Layer 1 — "label scheme: no collision")
//    - VVTerm/Features/Teleport/Domain/TeleportCluster.swift
//

import XCTest
@testable import VVTerm

final class TeleportClusterTests: XCTestCase {

    // MARK: - sepKeyLabel format

    func testSepKeyLabel_formatIsVvtermClusterColonUser() {
        let cluster = TeleportCluster(
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            clusterName: "teleport.pcad.it"
        )
        XCTAssertEqual(
            cluster.sepKeyLabel,
            "vvterm/teleport.pcad.it:pier"
        )
    }

    func testSepKeyLabel_usesClusterNameNotHost() {
        // The label uses `clusterName`, not `host`. These usually match,
        // but Teleport's cluster name can differ from the proxy host
        // (e.g. proxy "teleport.pcad.it" serving cluster "prod").
        let cluster = TeleportCluster(
            host: "teleport.pcad.it",
            username: "pier",
            clusterName: "prod-cluster"
        )
        XCTAssertEqual(cluster.sepKeyLabel, "vvterm/prod-cluster:pier")
    }

    func testSepKeyLabel_defaultsClusterNameToHost() {
        // When clusterName isn't explicitly set, it defaults to host.
        let cluster = TeleportCluster(host: "teleport.example.com", username: "alice")
        XCTAssertEqual(cluster.clusterName, "teleport.example.com")
        XCTAssertEqual(cluster.sepKeyLabel, "vvterm/teleport.example.com:alice")
    }

    func testSepKeyLabel_defaultsRpIDToHost() {
        // rpID also defaults to host (the WebAuthn RP ID).
        let cluster = TeleportCluster(host: "teleport.example.com", username: "alice")
        XCTAssertEqual(cluster.rpID, "teleport.example.com")
    }

    func testSepKeyLabel_defaultsPortTo443() {
        let cluster = TeleportCluster(host: "teleport.example.com", username: "alice")
        XCTAssertEqual(cluster.port, 443)
    }

    // MARK: - No collision across clusters

    func testSepKeyLabel_noCollisionAcrossClustersWithDifferentNames() {
        // Two distinct clusters with different names must produce different
        // labels — otherwise the SEP key from cluster A would be returned
        // when cluster B queries the keychain.
        let clusterA = TeleportCluster(
            host: "teleport.pcad.it",
            username: "pier",
            clusterName: "prod"
        )
        let clusterB = TeleportCluster(
            host: "staging.teleport.pcad.it",
            username: "pier",
            clusterName: "staging"
        )
        XCTAssertNotEqual(clusterA.sepKeyLabel, clusterB.sepKeyLabel)
    }

    func testSepKeyLabel_noCollisionAcrossUsersOnSameCluster() {
        // Two different users on the same cluster must produce different
        // labels — otherwise user A's SEP key would be used for user B.
        let userA = TeleportCluster(
            host: "teleport.pcad.it",
            username: "pier",
            clusterName: "teleport.pcad.it"
        )
        let userB = TeleportCluster(
            host: "teleport.pcad.it",
            username: "marie",
            clusterName: "teleport.pcad.it"
        )
        XCTAssertNotEqual(userA.sepKeyLabel, userB.sepKeyLabel)
    }

    func testSepKeyLabel_noCollisionAcrossClustersWithDifferentUsers() {
        // Different cluster + different user → different labels.
        let a = TeleportCluster(host: "a.example.com", username: "alice", clusterName: "a")
        let b = TeleportCluster(host: "b.example.com", username: "bob", clusterName: "b")
        XCTAssertNotEqual(a.sepKeyLabel, b.sepKeyLabel)
    }

    func testSepKeyLabel_sameClusterAndUserCollideIntentionally() {
        // Two `TeleportCluster` instances with the same clusterName + username
        // produce the same label — this is intentional (the label is the
        // stable keychain key for that cluster+user pair, and a re-created
        // `TeleportCluster` for the same server should find the existing key).
        let a1 = TeleportCluster(host: "teleport.pcad.it", username: "pier", clusterName: "teleport.pcad.it")
        let a2 = TeleportCluster(host: "teleport.pcad.it", username: "pier", clusterName: "teleport.pcad.it")
        XCTAssertEqual(a1.sepKeyLabel, a2.sepKeyLabel)
    }

    // MARK: - Multiple clusters

    func testSepKeyLabel_multipleClustersAllDistinct() {
        // A realistic fleet: 3 clusters, 2 users each. All 6 labels must be
        // distinct (no collision).
        let clusters: [TeleportCluster] = [
            TeleportCluster(host: "teleport.pcad.it", username: "pier", clusterName: "prod"),
            TeleportCluster(host: "teleport.pcad.it", username: "marie", clusterName: "prod"),
            TeleportCluster(host: "staging.teleport.pcad.it", username: "pier", clusterName: "staging"),
            TeleportCluster(host: "staging.teleport.pcad.it", username: "marie", clusterName: "staging"),
            TeleportCluster(host: "teleport.example.com", username: "alice", clusterName: "example"),
            TeleportCluster(host: "teleport.example.com", username: "bob", clusterName: "example"),
        ]
        let labels = clusters.map(\.sepKeyLabel)
        XCTAssertEqual(Set(labels).count, labels.count, "labels must all be distinct: \(labels)")
    }

    // MARK: - Identifiable / Hashable / Codable

    func testClusterIsIdentifiableByID() {
        // Each cluster has a unique UUID id (used for keychain lookup).
        let a = TeleportCluster(host: "h", username: "u")
        let b = TeleportCluster(host: "h", username: "u")
        XCTAssertNotEqual(a.id, b.id, "two clusters must have distinct UUIDs even if all other fields match")
    }

    func testClusterCodableRoundTrip() {
        let original = TeleportCluster(
            host: "teleport.pcad.it",
            port: 443,
            username: "pier",
            rpID: "teleport.pcad.it",
            clusterName: "prod"
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(TeleportCluster.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.rpID, original.rpID)
        XCTAssertEqual(decoded.clusterName, original.clusterName)
        XCTAssertEqual(decoded.sepKeyLabel, original.sepKeyLabel)
    }

    func testClusterHashableUsesAllFields() {
        // Two clusters with different IDs are not equal (the id is part of
        // Hashable). This lets clusters be used as Dictionary keys in the
        // key ring.
        let a = TeleportCluster(host: "h", username: "u", clusterName: "c")
        let b = TeleportCluster(host: "h", username: "u", clusterName: "c")
        XCTAssertNotEqual(a, b, "clusters with different UUIDs are not equal")
        XCTAssertNotEqual(a.hashValue, b.hashValue, "clusters with different UUIDs have different hashValues")
    }
}
