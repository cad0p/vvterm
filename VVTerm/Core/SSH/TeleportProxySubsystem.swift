// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  TeleportProxySubsystem.swift
//  VVTerm
//
//  Builds the `proxy:<node>:<port>[@<cluster>]` subsystem string Teleport's
//  proxy expects on its proxy-mode SSH listener.
//
//  Why this exists
//  ---------------
//  Teleport's proxy SSH listener (lib/srv/regular/proxy.go) runs in
//  `proxyMode`. It rejects `pty`/`shell`/`exec` channel requests with
//  `SSH_MSG_CHANNEL_FAILURE` (libssh2 surfaces this as
//  `LIBSSH2_ERROR_CHANNEL_REQUEST_FAILURE` / -22) and only accepts
//  `subsystem` channel requests whose name starts with `proxy:`.
//
//  The subsystem request opens a raw TCP tunnel from the proxy to the
//  target node's SSH service. VVTerm then runs a *second* full SSH
//  handshake (KEX + cert auth) over that tunnel to reach the node itself
//  — the proxy is just a relay, it does not terminate the user's shell.
//
//  Format (see lib/srv/regular/proxy.go parseProxySubsys):
//
//      proxy:<target-node>:<port>            # local (leaf) cluster
//      proxy:<target-node>:<port>@<cluster>  # remote (root) cluster
//
//  Port semantics
//  --------------
//  Port `0` tells the proxy to choose the node's real SSH port. The node's
//  own SSH service may not be on 22 (Teleport nodes register their SSH port
//  with the auth server when they join), and VVTerm does not know it ahead
//  of time. Passing `0` mirrors `tsh ssh <node>`, which never pins the node
//  port.
//
//  Cluster suffix semantics
//  ------------------------
//  The `@<cluster>` suffix is for leaf-cluster routing through a root
//  cluster (Teleport's trusted-cluster feature). When the target node lives
//  in the *local* cluster — the cluster the proxy belongs to — the suffix is
//  OMITTED: the proxy derives the local cluster name from the user cert's
//  `teleport-cluster` extension, so an explicit suffix would be redundant
//  (and malformed if it doesn't match). For the local-cluster MVP VVTerm
//  always omits it.
//

import Foundation

enum TeleportProxySubsystem {

    /// Builds the `proxy:<node>:<port>[@<cluster>]` subsystem string for
    /// Teleport's proxy.
    ///
    /// - Parameters:
    ///   - targetNode: The target node hostname (e.g. `pcad-dev.teleport.pcad.it`).
    ///     This is `Server.host` for a `.faceIDTeleport` server.
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
        for targetNode: String,
        port: Int = 0,
        cluster: String? = nil
    ) -> String {
        // A nil or empty cluster means "the local cluster" — the proxy derives
        // the cluster name from the user cert, so the `@<cluster>` suffix must
        // be omitted entirely. Appending `@` alone would be malformed.
        if let cluster, !cluster.isEmpty {
            return "proxy:\(targetNode):\(port)@\(cluster)"
        }
        return "proxy:\(targetNode):\(port)"
    }
}
