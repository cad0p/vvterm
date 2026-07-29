import Foundation

/// Configuration for a Teleport cluster. Stored as part of a `Server` record
/// (the Server's host is the TARGET NODE; the Teleport PROXY host lives here
/// on `TeleportCluster.host`, captured during the bootstrap phase).
/// CloudKit-synced via the parent `Server` record.
struct TeleportCluster: Codable, Hashable, Identifiable {
    let id: UUID
    /// The Teleport proxy host (e.g. "teleport.pcad.it"). Captured at
    /// bootstrap. Distinct from `Server.host`, which is the target node.
    var host: String
    /// The Teleport proxy port (e.g. 443). Mirrors Server.port.
    var port: Int
    /// The Teleport username (e.g. "pier"). Mirrors Server.username.
    /// Persisted via NSUbiquitousKeyValueStore for cross-device sync
    /// (the entitlement is already provisioned but unused).
    var username: String
    /// The WebAuthn RP ID (defaults to the host).
    var rpID: String
    /// The cluster name (e.g. "teleport.pcad.it"). Fetched from the cluster.
    var clusterName: String

    init(
        id: UUID = UUID(),
        host: String,
        port: Int = 443,
        username: String,
        rpID: String? = nil,
        clusterName: String? = nil
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.rpID = rpID ?? host
        self.clusterName = clusterName ?? host
    }

    /// The SEP keychain label for this cluster + user.
    /// Format: `vvterm/<cluster>:<user>` — matches tsh's per-cluster key isolation.
    var sepKeyLabel: String {
        "vvterm/\(clusterName):\(username)"
    }
}
