// SPDX-License-Identifier: MIT
//
//  TeleportKeyRing+Reuse.swift
//  VVTerm
//
//  The one shared reuse attempt for the add-server / row-tap entry points.
//
//  This is feature orchestration that spans two features
//  (`Features/Teleport/Domain/TeleportCredentialReuse` + `Features/Servers/Domain/Server`),
//  so it lives in `Features/Teleport/Application` rather than `Core/Teleport`:
//  `Core` keeps only the `TeleportKeyRingStoring` seam protocol and its
//  conformance, and stays feature-agnostic for the `cad0p/swift-teleport`
//  package port.
//
//  Must be called from a tap handler, never from a view body: it mutates the
//  observed keyring.
//

import Foundation

extension TeleportKeyRingStoring {
    /// The one shared reuse attempt for the add-server / row-tap entry points:
    /// finds a complete live registration for the same (proxy host, Teleport
    /// user, cluster) and seeds it into `newServer`'s row.
    ///
    /// Returns the source row's display name when seeding succeeded (for the
    /// reuse notice), or nil when there is no reusable source.
    ///
    /// Must be called from a tap handler, never from a view body: it mutates
    /// the observed keyring.
    func seedReuseIfPossible(for newServer: Server, liveServers: [Server]) -> String? {
        let newClusterName = clusterTLSState(for: newServer.id)?.clusterName
        guard let source = TeleportCredentialReuse.match(
            newServer: newServer,
            liveServers: liveServers,
            credentials: credentials,
            clusterName: { [weak self] id in self?.clusterTLSState(for: id)?.clusterName },
            isReusable: { [weak self] id in
                self?.isReusableRegistrationSource(for: id, clusterName: newClusterName) == true
            }
        ) else {
            return nil
        }
        guard seedRegistration(from: source.id, to: newServer.id) else { return nil }
        return source.name
    }
}
