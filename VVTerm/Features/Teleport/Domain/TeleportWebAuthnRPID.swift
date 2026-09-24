// SPDX-License-Identifier: MIT
//
//  TeleportWebAuthnRPID.swift
//  VVTerm
//
//  Resolves the WebAuthn Relying Party ID for the Teleport ceremonies.
//
//  The `rpID` comes back from the server (`login/begin`'s
//  `webauthn_challenge.publicKey.rpId` and the gRPC
//  `CreateRegisterChallenge`'s `webauthn.publicKey.rp.id`). It scopes the
//  credential: an assertion is only valid for the RP ID it was created
//  under, and the clientDataJSON origin is matched against it by the
//  server. A server that can hand the client an arbitrary RP ID could
//  direct the ceremony at a different origin, so the value must agree with
//  the cluster the user configured:
//
//    - expected = `cluster.rpID` when explicitly configured, else
//      `cluster.host`.
//    - an empty / missing server value means "use the configured value"
//      (the historical wire behavior for clusters without a custom
//      `webauthn.rp_id`).
//    - any other value fails closed.
//
//  Pure domain logic so both coordinators (Phase 2 registration, Phase 3
//  login) share one tested rule.
//

import Foundation

enum TeleportWebAuthnRPID {

    /// A rejected server-provided RP ID.
    enum ResolveError: Error, Equatable, LocalizedError {
        /// The cluster has no usable configured RP ID (empty host + rpID).
        case missingExpected
        /// The server provided an RP ID that is not the configured one.
        case mismatch(serverProvided: String, expected: String)

        var errorDescription: String? {
            switch self {
            case .missingExpected:
                return "no configured WebAuthn rpID for this cluster"
            case .mismatch(let serverProvided, let expected):
                return "WebAuthn rpID mismatch (server: \(serverProvided), expected: \(expected))"
            }
        }

        /// A log-safe rendering: the case only, so a `.public` log payload
        /// never carries the *server-provided* rpID. The descriptive text
        /// above belongs to the UI state.
        var logSafeDescription: String {
            switch self {
            case .missingExpected: return "missing expected rpID"
            case .mismatch: return "mismatch"
            }
        }
    }

    /// Resolve the RP ID to use for a ceremony.
    ///
    /// - Parameters:
    ///   - serverProvided: the RP ID from the server response (may be
    ///     `nil`; a `""` value is treated as absent).
    ///   - cluster: the configured cluster (host + optional custom rpID).
    /// - Returns: the configured RP ID on success; a `ResolveError` when
    ///   the server value disagrees or the cluster has no expected value.
    static func resolve(
        serverProvided: String?,
        cluster: TeleportCluster
    ) -> Result<String, ResolveError> {
        let configured = cluster.rpID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = (configured.isEmpty
            ? cluster.host.trimmingCharacters(in: .whitespacesAndNewlines)
            : configured)
        guard !expected.isEmpty else {
            return .failure(.missingExpected)
        }

        guard let provided = serverProvided?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provided.isEmpty else {
            // Absent/empty server value → the configured RP ID.
            return .success(expected)
        }

        // DNS names are case-insensitive; compare folded but return the
        // configured spelling so the client-built origin always matches the
        // RP ID we feed to the WebAuthn builder.
        guard provided.lowercased() == expected.lowercased() else {
            return .failure(.mismatch(serverProvided: provided, expected: expected))
        }
        return .success(expected)
    }
}
