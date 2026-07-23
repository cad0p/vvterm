import Foundation

/// Configuration for a Teleport cluster. Stored as part of a `Server` record
/// (the Server's host/port/username are reused for the Teleport proxy).
/// CloudKit-synced via the parent `Server` record.
struct TeleportCluster: Codable, Hashable, Identifiable {
    let id: UUID
    /// The Teleport proxy host (e.g. "teleport.pcad.it"). Mirrors Server.host.
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
