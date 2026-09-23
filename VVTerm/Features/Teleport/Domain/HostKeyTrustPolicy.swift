// SPDX-License-Identifier: AGPL-3.0-or-later
//
//  HostKeyTrustPolicy.swift
//  VVTerm
//
//  The pure decision function behind `SSHClient.verifyHostKey()` /
//  `verifyInnerHostKey()`.
//
//  - Teleport (`faceIDTeleport`): the Host CA is authoritative. The SSH host
//    certificate must chain to a pinned `checking_keys` entry; the
//    `KnownHostsManager` pin is refreshed/replaced on success and never used
//    to reject (the pin hashes the rotating certificate blob). Missing
//    anchors fail closed with an actionable "sign in / bootstrap" error.
//  - Non-Teleport: the existing fingerprint pin decides (first use is TOFU
//    until the first-use prompt lands).
//
//  Kept pure so the policy is unit-testable without a live libssh2 session.
//

import Foundation

enum HostKeyTrustPolicy {

    enum Decision: Equatable {
        /// Accept the host key. `refreshPin` means the caller should
        /// save/replace the known-hosts pin (new entry, rotated certificate,
        /// or a non-Teleport first use).
        case verified(refreshPin: Bool)
        /// A known pin mismatched the presented key (non-Teleport), or the
        /// presented host certificate did not verify against the Host CA.
        case rejectHostKeyVerification
        /// Teleport host but no Host CA checking keys are persisted — the
        /// user must log in (or bootstrap) before the SSH leg can verify.
        case rejectMissingTeleportAnchors
        /// Non-Teleport host with no pin: prompt the user (first-use).
        case unknownHost(fingerprint: String, keyType: Int)
    }

    static func decide(
        isTeleport: Bool,
        fingerprint: String,
        keyType: Int,
        knownFingerprint: String?,
        hostKeyBlob: Data,
        expectedPrincipals: [String],
        teleportHostCACheckingKeys: [String],
        now: Date
    ) -> Decision {
        if isTeleport {
            guard !teleportHostCACheckingKeys.isEmpty else {
                return .rejectMissingTeleportAnchors
            }
            let result = OpenSSHHostCertVerifier.verify(
                hostKeyBlob: hostKeyBlob,
                expectedPrincipals: expectedPrincipals,
                checkingKeys: teleportHostCACheckingKeys,
                now: now
            )
            switch result {
            case .verified:
                // Host CA is authoritative; always refresh the (rotating)
                // certificate pin instead of comparing it.
                return .verified(refreshPin: true)
            case .notACertificate,
                 .noMatchingCAKey,
                 .badSignature,
                 .expired,
                 .principalMismatch,
                 .unsupportedCAKeyType:
                return .rejectHostKeyVerification
            }
        }

        if let knownFingerprint {
            return knownFingerprint == fingerprint
                ? .verified(refreshPin: false)
                : .rejectHostKeyVerification
        }
        return .unknownHost(fingerprint: fingerprint, keyType: keyType)
    }
}
