// SPDX-License-Identifier: MIT
//
//  TeleportCredentialInvalidating.swift
//  VVTerm
//
//  The record-level invalidation seam for Teleport credentials.
//
//  `Features/Servers` owns the server rows, but the credential for a row lives
//  in the Teleport keyring. When the identity a credential was created for
//  changes — the proxy host or the Teleport user — the credential must be
//  cleared so readiness flips to `.needsBootstrap` and setup runs for the new
//  identity (a stale cert otherwise silently fails the connect: #262).
//
//  The seam is deliberately tiny and read+write: the read (`hasCredential`,
//  `certKeyID`) is what makes the clear rule implementable without clearing a
//  same-host rename back to the credential's own user.
//
//  Conformers: `TeleportKeyRing` (production) and `MockTeleportKeyRing`
//  (UI-test/harness), both `@MainActor` because they are observed by SwiftUI.
//

import Foundation

/// Where the connect-time fail-closed condition clears the credential, and the
/// server-manager invalidation rule clears it on identity edits.
@MainActor
protocol TeleportCredentialInvalidating: AnyObject {
    /// Whether a credential *record* exists for this row. Record presence, not
    /// cert presence: a reuse-seeded record has no cert yet but must still be
    /// invalidatable.
    func hasCredential(for serverId: UUID) -> Bool

    /// The `keyID` (the Teleport user) of the credential's stored certificate,
    /// parsed from its stored PEM regardless of validity, or nil.
    func certKeyID(for serverId: UUID) -> String?

    /// Clear the credential record (and its cluster TLS state / ed25519 key).
    func clearCredential(for serverId: UUID)
}

/// The exact rule for clearing a Teleport credential when a server row's
/// identity fields change. Pure so it is fully unit-testable.
enum TeleportCredentialInvalidationPolicy {
    /// - Parameters:
    ///   - oldHost: the row's previous proxy host.
    ///   - newHost: the row's new proxy host.
    ///   - oldUsername: the row's previous Teleport user.
    ///   - newUsername: the row's new Teleport user.
    ///   - hasCredential: whether the row currently has a credential record.
    ///   - certKeyID: the stored certificate's keyID (Teleport user), if any.
    ///
    /// Rule:
    /// ```
    /// if !hasCredential { return false }
    /// if hostChanged { clear }                       // may be for the old host
    /// if usernameChanged, certKeyID != newUsername { clear }
    /// // same-host rename back to the credential's own user → keep
    /// ```
    /// Node-name and port changes never invalidate (the cert is per user, not
    /// per node).
    static func shouldClearCredential(
        oldHost: String,
        newHost: String,
        oldUsername: String,
        newUsername: String,
        hasCredential: Bool,
        certKeyID: String?
    ) -> Bool {
        guard hasCredential else { return false }
        if oldHost != newHost { return true }
        if oldUsername != newUsername { return certKeyID != newUsername }
        return false
    }
}

extension TeleportKeyRing: TeleportCredentialInvalidating {
    /// Record presence, not cert presence (a reuse-seeded record has no cert).
    func hasCredential(for serverId: UUID) -> Bool {
        credentials[serverId] != nil
    }

    func certKeyID(for serverId: UUID) -> String? {
        guard let certPEM = credentials[serverId]?.sshCertPEM else { return nil }
        return OpenSSHCertificate.parse(authorizedKeysOrPEM: certPEM)?.keyID
    }

    func clearCredential(for serverId: UUID) {
        clear(for: serverId)
    }
}
