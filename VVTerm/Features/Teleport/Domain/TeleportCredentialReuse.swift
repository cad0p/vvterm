// SPDX-License-Identifier: MIT
//
//  TeleportCredentialReuse.swift
//  VVTerm
//
//  The pure matcher that lets a duplicate server row reuse an existing
//  device registration.
//
//  A Teleport SEP key belongs to a (cluster, Teleport user) — not to a node.
//  Registering a second row for the same cluster + user does not need a second
//  MFA device registration (and the cluster's device-name collision makes one
//  awkward): the row can seed the registration metadata (credentialID,
//  userHandle, publicKeyRaw, deviceName + cluster TLS state) from a complete
//  live setup and go straight to Face ID login + the host-login picker.
//
//  The keyring is keyed by server UUID only and cannot match on host/user, so
//  the matcher takes the live `[Server]` list plus the credential map. The
//  completeness precondition is injected as `isReusable` so this type stays
//  pure and unit-testable.
//
//  Match key: the candidate must be a different `.faceIDTeleport` row with the
//  same `host` and `username` (the Teleport user) as the new row, and a
//  complete live registration. When the new row already knows its cluster name
//  (a re-setup of an existing row) the cluster names must also be equal — a
//  proxy host can front several clusters. A brand-new row has no cluster name
//  yet, so host+user is its only discriminator (recorded: two proxies on one
//  host with different ports collide — deliberate).
//
//  See:
//    - [[open-source/github/vvterm/2026-09-27-issue262-host-login-plan]]
//

import Foundation

enum TeleportCredentialReuse {

    /// The completeness precondition for a candidate row's registration:
    /// a credential record with a non-empty `credentialID`, the SEP key still
    /// present, and a cluster TLS state with non-empty Host CA checking keys.
    typealias IsReusable = (UUID) -> Bool

    /// The first reusable live source row for `newServer`, or nil.
    ///
    /// - Parameters:
    ///   - newServer: the row being set up.
    ///   - liveServers: the live server list (`ServerManager.servers`).
    ///   - credentials: the keyring's credential map.
    ///   - clusterName: the cluster name persisted in the keyring's TLS state
    ///     for a row, or nil when the row has none yet.
    ///   - isReusable: the completeness precondition (see `IsReusable`).
    static func match(
        newServer: Server,
        liveServers: [Server],
        credentials: [UUID: TeleportCredential],
        clusterName: (UUID) -> String?,
        isReusable: IsReusable
    ) -> Server? {
        guard newServer.authMethod == .faceIDTeleport else { return nil }
        let newClusterName = clusterName(newServer.id)

        return liveServers
            .filter { candidate in
                guard candidate.id != newServer.id else { return false }
                guard candidate.authMethod == .faceIDTeleport else { return false }
                guard candidate.host == newServer.host, candidate.username == newServer.username else {
                    return false
                }
                guard credentials[candidate.id] != nil else { return false }
                return isReusable(candidate.id)
            }
            .filter { candidate in
                // A brand-new row has no cluster name yet; when it does, the
                // candidate must belong to the same cluster.
                guard let newClusterName, !newClusterName.isEmpty else { return true }
                guard let candidateClusterName = clusterName(candidate.id) else { return false }
                return candidateClusterName == newClusterName
            }
            .sorted { $0.name < $1.name }
            .first
    }
}
