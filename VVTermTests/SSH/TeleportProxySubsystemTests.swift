// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportProxySubsystemTests.swift
//  VVTerm
//
//  Unit coverage for `TeleportProxySubsystem.request(for:port:cluster:)`,
//  which builds the `proxy:<node>:<port>[@<cluster>]` subsystem string the
//  Teleport proxy expects on its proxy-mode SSH listener.
//
//  Teleport's proxy listener (lib/srv/regular/proxy.go) runs in proxyMode:
//  it rejects `pty`/`shell`/`exec` channel requests and only accepts
//  `subsystem` requests whose name starts with `proxy:`. The format is:
//
//      proxy:<target-node>:<port>            # local (leaf) cluster
//      proxy:<target-node>:<port>@<cluster>  # remote (root) cluster
//
//  Port `0` tells the proxy to choose the node's real SSH port (the node's
//  own SSH service may not be on 22). VVTerm always passes `0` and lets the
//  proxy resolve it — mirroring `tsh ssh <node>`'s proxy subsystem request.
//

import Testing
@testable import VVTerm

struct TeleportProxySubsystemTests {

    // MARK: - Local (leaf) cluster

    @Test
    func localClusterEmitsProxyNodePortWithoutClusterSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "pcad-dev", clusterHost: "teleport.example.com")
        #expect(subsystem == "proxy:pcad-dev:0")
    }

    @Test
    func localClusterWithExplicitPortIncludesPort() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 22)
        #expect(subsystem == "proxy:node-1:22")
    }

    @Test
    func localClusterWithNilClusterOmitsAtSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "web-1", clusterHost: "teleport.example.com", port: 0, cluster: nil)
        #expect(subsystem == "proxy:web-1:0")
        #expect(!subsystem.contains("@"))
    }

    @Test
    func localClusterWithEmptyClusterStringOmitsAtSuffix() {
        // An empty cluster string must behave identically to `nil` — the
        // proxy derives the local cluster from the cert, so an empty suffix
        // would be malformed (`proxy:node:0@`).
        let subsystem = TeleportProxySubsystem.request(for: "db-1", clusterHost: "teleport.example.com", port: 0, cluster: "")
        #expect(subsystem == "proxy:db-1:0")
        #expect(!subsystem.contains("@"))
    }

    // MARK: - Remote (root) cluster

    @Test
    func remoteClusterAppendsAtClusterSuffix() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 0, cluster: "root-cluster")
        #expect(subsystem == "proxy:node-1:0@root-cluster")
    }

    @Test
    func remoteClusterWithExplicitPortIncludesBothPortAndCluster() {
        let subsystem = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 2222, cluster: "staging")
        #expect(subsystem == "proxy:node-1:2222@staging")
    }

    // MARK: - Defaults

    @Test
    func portDefaultsToZeroWhenOmitted() {
        // Port `0` is the VVTerm default — the proxy chooses the node's real
        // SSH port. This mirrors `tsh ssh`, which never pins the node port.
        let subsystem = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com")
        #expect(subsystem == "proxy:node-1:0")
    }

    // MARK: - Structural invariants

    @Test
    func subsystemAlwaysStartsWithProxyPrefix() {
        for variant in [
            TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com"),
            TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 22),
            TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 0, cluster: "c"),
            TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 0, cluster: nil)
        ] {
            #expect(variant.hasPrefix("proxy:"))
        }
    }

    @Test
    func subsystemHasExactlyOneAtSignWhenClusterPresent() {
        let local = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com")
        #expect(local.filter { $0 == "@" }.count == 0)

        let remote = TeleportProxySubsystem.request(for: "node-1", clusterHost: "teleport.example.com", port: 0, cluster: "root")
        #expect(remote.filter { $0 == "@" }.count == 1)
    }

    @Test
    func targetNodeWithColonsIsPreservedVerbatim() {
        // A target node hostname could itself contain a port-style colon
        // (unusual, but the builder must not reinterpret it). The builder
        // only adds the `:port` after the node; it does not parse the node.
        let subsystem = TeleportProxySubsystem.request(for: "node-1.internal", clusterHost: "teleport.example.com")
        #expect(subsystem == "proxy:node-1.internal:0")
    }

    // MARK: - FQDN suffix stripping

    @Test
    func resolveNodeName_stripsClusterSuffixFromFQDN() {
        // pcad-dev.teleport.pcad.it + teleport.pcad.it → pcad-dev
        // Teleport registers nodes by short name, but users enter the FQDN
        // for self-documentation.
        let resolved = TeleportProxySubsystem.resolveNodeName("pcad-dev.teleport.pcad.it", clusterHost: "teleport.pcad.it")
        #expect(resolved == "pcad-dev")
    }

    @Test
    func resolveNodeName_passesShortNameThroughUnchanged() {
        // If the user already entered the short name, no suffix to strip.
        let resolved = TeleportProxySubsystem.resolveNodeName("pcad-dev", clusterHost: "teleport.pcad.it")
        #expect(resolved == "pcad-dev")
    }

    @Test
    func resolveNodeName_doesNotStripPartialSuffix() {
        // Don't strip if the suffix doesn't match exactly.
        let resolved = TeleportProxySubsystem.resolveNodeName("pcad-dev.other.com", clusterHost: "teleport.pcad.it")
        #expect(resolved == "pcad-dev.other.com")
    }

    @Test
    func request_stripsFQDNSuffixFromSubsystemString() {
        // The full path: FQDN in → short name in subsystem string.
        let subsystem = TeleportProxySubsystem.request(for: "pcad-dev.teleport.pcad.it", clusterHost: "teleport.pcad.it")
        #expect(subsystem == "proxy:pcad-dev:0")
    }
}
