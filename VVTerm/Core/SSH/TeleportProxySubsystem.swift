// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportProxySubsystem.swift
//  VVTerm
//
//  Builds the `proxy:<node>:<port>[@<cluster>]` subsystem string for
//  Teleport's proxy. The proxy is in `proxyMode` — it rejects `pty`/`shell`/
//  `exec` channel requests and only accepts `subsystem` requests. The
//  `proxy:<node>:<port>` subsystem tells the proxy to forward the channel
//  as a raw TCP tunnel to the target node's SSH service.
//
//  The node name is `Server.name` (the display name the user enters).
//  For Teleport servers, the display name IS the node name — the user
//  names the server after the node it connects to (e.g. "pcad-dev").
//
//  Port `0` tells the proxy to choose the node's real SSH port (3022 for
//  Teleport nodes, 22 for OpenSSH/agentless nodes). VVTerm doesn't know
//  which, and `tsh ssh` passes `0` for the same reason.
//
//  See:
//    - lib/srv/regular/proxy.go:79-117 (parseProxySubsysRequest)
//    - api/utils/route.go:152 (port 0 = "not specified")
//

import Foundation

enum TeleportProxySubsystem {

    /// Builds the `proxy:<node>:<port>[@<cluster>]` subsystem string for
    /// Teleport's proxy.
    ///
    /// - Parameters:
    ///   - nodeName: The target node name (e.g. `pcad-dev`). This is
    ///     `Server.name` for a `.faceIDTeleport` server. Teleport registers
    ///     nodes by name (defaults to `hostname` output, overridable via
    ///     `nodename` in teleport.yaml). May contain dots and hyphens.
    ///   - port: The target node's SSH port. `0` (the default) tells the proxy
    ///     to choose the node's real SSH port — VVTerm does not know it ahead
    ///     of time, and `tsh ssh` passes `0` for the same reason.
    ///   - cluster: The leaf cluster name, or `nil`/empty for the local
    ///     cluster. When non-empty, `@<cluster>` is appended so the proxy
    ///     routes the tunnel through the trusted-cluster connection to the
    ///     leaf cluster's proxy.
    /// - Returns: The subsystem string to pass to
    ///   `libssh2_channel_process_startup(channel, "subsystem", 9, ...)`.
    static func request(
        for nodeName: String,
        port: Int = 0,
        cluster: String? = nil
    ) -> String {
        let node = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A nil or empty cluster means "the local cluster" — the proxy derives
        // the cluster name from the user cert, so the `@<cluster>` suffix must
        // be omitted entirely. Appending `@` alone would be malformed.
        if let cluster, !cluster.isEmpty {
            return "proxy:\(node):\(port)@\(cluster)"
        }
        return "proxy:\(node):\(port)"
    }
}
