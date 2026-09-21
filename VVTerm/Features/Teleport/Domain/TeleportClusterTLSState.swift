// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportClusterTLSState.swift
//  VVTerm
//
//  The cluster name + TLS CA certs + Host CA checking keys captured at
//  Phase 1 bootstrap, persisted in `TeleportKeyRing` for the SSH TLS+ALPN
//  transport.
//
//  These come from the headless-login response's `host_signers[0]`:
//    - `domain_name`     → clusterName
//    - `tls_certs`       → clusterCAPEMs (base64(PEM) decoded to PEM strings)
//    - `checking_keys`   → hostCACheckingKeys (base64(authorized_keys line)
//                          decoded to authorized_keys lines — the Host CA
//                          SSH public keys that sign host certificates)
//
//  The SSH path (`SSHTLSTransport`) uses the TLS certs as NWProtocolTLS
//  trust anchors when dialing the Teleport proxy on port 443 (TLS Routing,
//  ALPN `teleport-proxy-ssh`); `OpenSSHHostCertVerifier` uses the checking
//  keys to verify the SSH host certificates presented by the proxy and the
//  target nodes. Persisted here so the SSH connect can rebuild the trust
//  store without a network round-trip.
//

import Foundation

/// The cluster name + trust anchors for a Teleport cluster, persisted for the
/// SSH TLS+ALPN transport. NOT CloudKit-synced (per-device — each device
/// must run its own Phase 1 bootstrap to capture these).
struct TeleportClusterTLSState: Codable, Hashable, Sendable {
    /// The cluster name (e.g. "teleport.pcad.it"), from
    /// host_signers[0].domain_name. Used for SNI + diagnostics.
    let clusterName: String
    /// The cluster's TLS CA certs (PEM strings), from
    /// host_signers[0].tls_certs. Used as NWProtocolTLS trust anchors.
    let clusterCAPEMs: [String]
    /// The Host CA SSH public keys (authorized_keys lines), from
    /// host_signers[0].checking_keys. Used to verify SSH host certificates.
    let hostCACheckingKeys: [String]

    init(
        clusterName: String,
        clusterCAPEMs: [String],
        hostCACheckingKeys: [String] = []
    ) {
        self.clusterName = clusterName
        self.clusterCAPEMs = clusterCAPEMs
        self.hostCACheckingKeys = hostCACheckingKeys
    }

    private enum CodingKeys: String, CodingKey {
        case clusterName
        case clusterCAPEMs
        case hostCACheckingKeys
    }

    /// Legacy payloads (written before checking keys were persisted) have no
    /// `hostCACheckingKeys`; decode them as an empty list so one old entry
    /// does not drop the whole persisted map.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clusterName = try container.decode(String.self, forKey: .clusterName)
        clusterCAPEMs = try container.decode([String].self, forKey: .clusterCAPEMs)
        hostCACheckingKeys = try container.decodeIfPresent([String].self, forKey: .hostCACheckingKeys) ?? []
    }
}

/// The result of refreshing the Host CA checking keys from a login response.
enum TeleportHostKeyUpdateResult: Equatable {
    /// The additions-only update was applied.
    case updated
    /// The refresh did not contain every currently pinned key — the pinned
    /// anchors are kept and the caller should surface re-bootstrap.
    case rejectedWouldDropPinnedKeys
    /// The refresh carried no usable keys, or was identical to the pinned set.
    case noChange
}

/// `checking_keys` elements are base64 of an *authorized_keys line*
/// (`ssh-ed25519 AAAA… type=host`), not base64(PEM). Shared by the headless
/// + login wire decoding and the bootstrap coordinator.
enum TeleportHostCACheckingKeysDecoder {

    /// Decode one `checking_keys` element. Returns nil when the value is not
    /// a base64-authorized_keys line.
    static func decode(_ base64Value: String) -> String? {
        guard let data = Data(base64Encoded: base64Value),
              let line = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Decode every element, dropping malformed entries.
    static func decodeAll(_ base64Values: [String]) -> [String] {
        base64Values.compactMap(decode)
    }

    /// Normalize authorized_keys lines to their parsed key blobs, preserving
    /// the first line seen for each blob (comments may differ across
    /// responses but the key material is what matters).
    static func normalizedLines(_ lines: [String]) -> [String] {
        var seen = Set<Data>()
        var normalized: [String] = []
        for line in lines {
            guard let blob = OpenSSHCertificate.parseAuthorizedKeysLine(line)?.blob else { continue }
            guard !seen.contains(blob) else { continue }
            seen.insert(blob)
            normalized.append(line)
        }
        return normalized
    }
}

/// The additions-only rule for refreshing the pinned Host CA checking keys.
/// Shared by the live + mock keyrings so the security rule has one
/// implementation.
enum TeleportHostKeyUpdatePolicy {

    /// Apply a refresh to a cluster's TLS state.
    ///
    /// - Returns: the outcome plus the state to persist; `updatedState` is nil
    ///   when the current state must be kept unchanged.
    static func apply(
        checkingKeys: [String],
        to state: TeleportClusterTLSState
    ) -> (result: TeleportHostKeyUpdateResult, updatedState: TeleportClusterTLSState?) {
        let normalized = TeleportHostCACheckingKeysDecoder.normalizedLines(checkingKeys)
        let newBlobs = Set(normalized.compactMap { OpenSSHCertificate.parseAuthorizedKeysLine($0)?.blob })
        guard !newBlobs.isEmpty else {
            return (.noChange, nil)
        }
        let pinnedBlobs = Set(
            state.hostCACheckingKeys.compactMap { OpenSSHCertificate.parseAuthorizedKeysLine($0)?.blob }
        )
        guard pinnedBlobs.isSubset(of: newBlobs) else {
            return (.rejectedWouldDropPinnedKeys, nil)
        }
        if newBlobs == pinnedBlobs {
            return (.noChange, nil)
        }
        let updated = TeleportClusterTLSState(
            clusterName: state.clusterName,
            clusterCAPEMs: state.clusterCAPEMs,
            hostCACheckingKeys: normalized
        )
        return (.updated, updated)
    }
}
