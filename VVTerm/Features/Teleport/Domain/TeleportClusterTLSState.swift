// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportClusterTLSState.swift
//  VVTerm
//
//  The cluster name + TLS CA certs captured at Phase 1 bootstrap, persisted
//  in `TeleportKeyRing` for the SSH TLS+ALPN transport.
//
//  These come from the headless-login response's `host_signers[0]`:
//    - `domain_name` → clusterName
//    - `tls_certs`   → clusterCAPEMs (base64(PEM) decoded to PEM strings)
//
//  The SSH path (`SSHTLSTransport`) uses them as NWProtocolTLS trust anchors
//  when dialing the Teleport proxy on port 443 (TLS Routing, ALPN
//  `teleport-proxy-ssh`). Same cluster CA the gRPC path uses for the
//  auth-service ALPN dial — persisted here so the SSH connect can rebuild
//  the TLS options without a network round-trip.
//

import Foundation

/// The cluster name + TLS CA certs for a Teleport cluster, persisted for the
/// SSH TLS+ALPN transport. NOT CloudKit-synced (per-device — each device
/// must run its own Phase 1 bootstrap to capture these).
struct TeleportClusterTLSState: Codable, Hashable, Sendable {
    /// The cluster name (e.g. "teleport.pcad.it"), from
    /// host_signers[0].domain_name. Used for SNI + diagnostics.
    let clusterName: String
    /// The cluster's TLS CA certs (PEM strings), from
    /// host_signers[0].tls_certs. Used as NWProtocolTLS trust anchors.
    let clusterCAPEMs: [String]

    init(clusterName: String, clusterCAPEMs: [String]) {
        self.clusterName = clusterName
        self.clusterCAPEMs = clusterCAPEMs
    }
}
