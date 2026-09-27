// SPDX-License-Identifier: MIT
//
//  TeleportHostLogin.swift
//  VVTerm
//
//  The pure resolver for the Teleport SSH username.
//
//  A Teleport SSH connection authenticates as the Teleport *user* (`pier`),
//  but the username libssh2 sends must be a **certificate principal** — the
//  host login (`deploy`). Teleport's `CertChecker.CheckCert` (x/crypto) runs
//  on the proxy and the node alike and rejects a username that is not one of
//  the certificate's `ValidPrincipals`, no matter how valid the certificate
//  itself is.
//
//  The resolution order is deliberately fail-closed:
//
//    1. The stored `Server.teleportHostLogin`, if it is still a principal of
//       the certificate being sent (a role change may have dropped it).
//    2. Otherwise, only when the certificate carries **exactly one**
//       non-internal principal, that principal (the legacy/no-picker path).
//    3. Zero principals or an ambiguous set fails closed — the connect path
//       never guesses among logins, and never sends a non-principal.
//
//  Internal principals (`-teleport-internal-join` and any other `-…` name)
//  are filtered before both the stored-match and the fallback, mirroring
//  `tsh status`'s `Logins:` list. Principal order is the certificate's wire
//  order.
//
//  See:
//    - [[open-source/github/vvterm/issues/2026-09-26-issue-teleport-auth-failed-user-mismatch]]
//    - VVTerm/Core/SSH/SSHClient.swift (the two auth sites)
//

import Foundation

/// Why the SSH username could not be resolved from the certificate.
enum TeleportHostLoginFailure: Error, Equatable, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The stored certificate could not be parsed as an OpenSSH certificate.
    case certificateUnreadable
    /// The certificate carries no non-internal principal.
    case noPrincipals
    /// The certificate carries several non-internal principals and no stored
    /// login matches one of them — the client must not guess.
    case ambiguousPrincipalSet([String])

    /// A stable, non-rendering case name for logs and diagnostics. The
    /// associated principal list is deliberately omitted so it can never
    /// reach the shareable diagnostics report through `String(describing:)`.
    var caseDescription: String {
        switch self {
        case .certificateUnreadable: return "certificateUnreadable"
        case .noPrincipals: return "noPrincipals"
        case .ambiguousPrincipalSet: return "ambiguousPrincipalSet"
        }
    }

    /// `String(describing:)` (logs, diagnostics) renders the case name only;
    /// the user-facing message stays in `errorDescription`.
    var description: String { caseDescription }

    /// `debugPrint` / `String(reflecting:)` render the case name only.
    var debugDescription: String { caseDescription }

    /// `dump(_:)` and `Mirror(reflecting:)` bypass `description` and read the
    /// reflection surface. The synthesized mirror exposed the associated
    /// principal list (`["deploy", "root"]`), so the custom mirror keeps
    /// reflection payload-free: a single labelled child carrying the stable
    /// case name.
    var customMirror: Mirror {
        Mirror(self, children: [(label: "case", value: caseDescription)], displayStyle: .enum)
    }

    var errorDescription: String? {
        switch self {
        case .certificateUnreadable:
            return String(localized: "The Teleport certificate could not be read. Sign in with Face ID to refresh it.")
        case .noPrincipals:
            return String(localized: "The Teleport certificate carries no login for this host. Ask an administrator to grant a login for this host on the Teleport role, then sign in again.")
        case .ambiguousPrincipalSet(let logins):
            return String(
                format: String(localized: "The Teleport certificate carries several logins (%@). Re-run Teleport setup and pick the host login to use."),
                logins.joined(separator: ", ")
            )
        }
    }
}

enum TeleportHostLogin {

    /// Resolve the SSH username for a Teleport connection from the certificate
    /// PEM that is being sent and the stored preference.
    static func resolveUsername(
        certPEM: String,
        storedLogin: String?
    ) -> Result<String, TeleportHostLoginFailure> {
        guard let cert = OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM) else {
            return .failure(.certificateUnreadable)
        }
        return resolve(cert: cert, storedLogin: storedLogin)
    }

    /// The parsed-certificate form of `resolveUsername` (used at the connect
    /// sites, which already had to parse the certificate for the keyID
    /// binding check).
    static func resolve(
        cert: OpenSSHCertificate,
        storedLogin: String?
    ) -> Result<String, TeleportHostLoginFailure> {
        let logins = nonInternalPrincipals(of: cert)

        if let stored = Server.normalizedTeleportHostLogin(storedLogin), logins.contains(stored) {
            return .success(stored)
        }

        switch logins.count {
        case 1:
            return .success(logins[0])
        case 0:
            return .failure(.noPrincipals)
        default:
            return .failure(.ambiguousPrincipalSet(logins))
        }
    }

    /// The certificate's non-internal principals in wire order (tsh `Logins:`
    /// parity). Internal Teleport principals are prefixed with `-`.
    static func nonInternalPrincipals(of cert: OpenSSHCertificate) -> [String] {
        cert.validPrincipals.filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    /// The host login the setup Phase-3 step starts with (the pure selection
    /// policy, kept out of the view).
    ///
    /// - A stored login that is still a principal of the fresh certificate is
    ///   the frozen per-row choice; the step renders it read-only.
    /// - A single non-internal principal is auto-selected but still shown.
    /// - Several non-internal principals with no stored login start with
    ///   **no selection**: the user must tap one explicitly, so Continue can
    ///   never freeze whichever login the CA happened to list first.
    static func initialSelection(logins: [String], stored: String?) -> String? {
        if let stored = Server.normalizedTeleportHostLogin(stored), logins.contains(stored) {
            return stored
        }
        return logins.count == 1 ? logins[0] : nil
    }
}
