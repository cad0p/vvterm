// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportProxySubsystemTests.swift
//  VVTermTests
//
//  Unit coverage for `TeleportProxySubsystem.request(for:port:cluster:)`.
//
//  The node name is `Server.name` (the display name). For Teleport servers,
//  the display name IS the node name the user enters (e.g. "pcad-dev").
//  Teleport registers nodes by name (defaults to `hostname`, overridable via
//  `nodename` in teleport.yaml). The name may contain dots and hyphens.
//

import Testing
@testable import VVTerm

struct TeleportProxySubsystemTests {

    // MARK: - Local (leaf) cluster

    @Test
    func localClusterEmitsProxyNodePortWithoutClusterSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "pcad-dev")
        #expect(subsystem == "proxy:pcad-dev:0")
    }

    @Test
    func localClusterWithExplicitPortIncludesPort() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", port: 22)
        #expect(subsystem == "proxy:node-1:22")
    }

    @Test
    func localClusterWithNilClusterOmitsAtSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "web-1", port: 0, cluster: nil)
        #expect(subsystem == "proxy:web-1:0")
        #expect(!subsystem.contains("@"))
    }

    @Test
    func localClusterWithEmptyClusterStringOmitsAtSuffix() {
        // An empty cluster string must behave identically to `nil` — the
        // proxy derives the local cluster from the cert, so an empty suffix
        // would be malformed (`proxy:node:0@`).
        let subsystem = TeleportProxySubsystem.request(for: "db-1", port: 0, cluster: "")
        #expect(subsystem == "proxy:db-1:0")
        #expect(!subsystem.contains("@"))
    }

    // MARK: - Node names with dots (nodename may contain dots per Teleport config)

    @Test
    func nodeNameWithDotsIsPreservedVerbatim() {
        // Teleport's nodename config allows dots (e.g. "web.frontend.01").
        // The builder must not reinterpret the node name — it's used as-is.
        let subsystem = TeleportProxySubsystem.request(for: "web.frontend.01")
        #expect(subsystem == "proxy:web.frontend.01:0")
    }

    // MARK: - Remote (root) cluster

    @Test
    func remoteClusterAppendsAtClusterSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: "root-cluster")
        #expect(subsystem == "proxy:node-1:0@root-cluster")
    }

    @Test
    func remoteClusterWithExplicitPortIncludesBothPortAndCluster() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", port: 2222, cluster: "staging")
        #expect(subsystem == "proxy:node-1:2222@staging")
    }

    // MARK: - Defaults

    @Test
    func portDefaultsToZeroWhenOmitted() {
        // Port `0` is the VVTerm default — the proxy chooses the node's real
        // SSH port. This mirrors `tsh ssh`, which never pins the node port.
        let subsystem = TeleportProxySubsystem.request(for: "node-1")
        #expect(subsystem == "proxy:node-1:0")
    }

    // MARK: - Structural invariants

    @Test
    func subsystemAlwaysStartsWithProxyPrefix() {
        for variant in [
            TeleportProxySubsystem.request(for: "node-1"),
            TeleportProxySubsystem.request(for: "node-1", port: 22),
            TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: "c"),
            TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: nil)
        ] {
            #expect(variant.hasPrefix("proxy:"))
        }
    }

    @Test
    func subsystemHasExactlyOneAtSignWhenClusterPresent() {
        let local = TeleportProxySubsystem.request(for: "node-1")
        #expect(local.filter { $0 == "@" }.count == 0)

        let remote = TeleportProxySubsystem.request(for: "node-1", port: 0, cluster: "root")
        #expect(remote.filter { $0 == "@" }.count == 1)
    }
}
