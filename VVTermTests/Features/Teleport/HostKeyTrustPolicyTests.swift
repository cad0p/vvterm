// SPDX-License-Identifier: MIT
//
//  HostKeyTrustPolicyTests.swift
//  VVTermTests
//
//  Pure coverage for the SSH host-key trust policy:
//    - Teleport: Host CA is authoritative; the pin is refreshed, never used
//      to reject; missing anchors fail closed.
//    - Non-Teleport: the fingerprint pin decides.
//

#if DEBUG
import Foundation
import Testing
@testable import VVTerm

struct HostKeyTrustPolicyTests {

    private static let validNow = Date(timeIntervalSince1970: 1_798_761_600)

    private static let caEd25519 = TeleportFixtureSupport
        .fixtureString("OpenSSH/ca_ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let hostCertLine = TeleportFixtureSupport
        .fixtureString("OpenSSH/host-cert-ed25519.pub")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    private static let hostCertBlob = OpenSSHCertificate.parseAuthorizedKeysLine(hostCertLine)?.blob ?? Data()

    // MARK: - Teleport

    @Test
    func teleportVerifiesAgainstTheHostCAAndRefreshesThePin() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: true,
            fingerprint: "SHA256:whatever",
            keyType: 0,
            knownFingerprint: "SHA256:old-rotated-cert",
            hostKeyBlob: Self.hostCertBlob,
            expectedPrincipals: ["testhost"],
            teleportHostCACheckingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(decision == .verified(refreshPin: true))
    }

    @Test
    func teleportRejectsCertThatDoesNotChainToThePinnedCA() {
        let foreignCA = TeleportFixtureSupport
            .fixtureString("OpenSSH/ca_foreign.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: true,
            fingerprint: "SHA256:whatever",
            keyType: 0,
            knownFingerprint: nil,
            hostKeyBlob: Self.hostCertBlob,
            expectedPrincipals: ["testhost"],
            teleportHostCACheckingKeys: [foreignCA],
            now: Self.validNow
        )
        #expect(decision == .rejectHostKeyVerification)
    }

    @Test
    func teleportRejectsPrincipalMismatch() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: true,
            fingerprint: "SHA256:whatever",
            keyType: 0,
            knownFingerprint: nil,
            hostKeyBlob: Self.hostCertBlob,
            expectedPrincipals: ["not-the-cert-principal"],
            teleportHostCACheckingKeys: [Self.caEd25519],
            now: Self.validNow
        )
        #expect(decision == .rejectHostKeyVerification)
    }

    @Test
    func teleportFailsClosedWithoutPinnedAnchors() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: true,
            fingerprint: "SHA256:whatever",
            keyType: 0,
            knownFingerprint: nil,
            hostKeyBlob: Self.hostCertBlob,
            expectedPrincipals: ["testhost"],
            teleportHostCACheckingKeys: [],
            now: Self.validNow
        )
        #expect(decision == .rejectMissingTeleportAnchors)
    }

    // MARK: - Non-Teleport

    @Test
    func nonTeleportFirstUseIsUnknown() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: false,
            fingerprint: "SHA256:abc",
            keyType: 1,
            knownFingerprint: nil,
            hostKeyBlob: Data(),
            expectedPrincipals: [],
            teleportHostCACheckingKeys: [],
            now: Self.validNow
        )
        #expect(decision == .unknownHost(fingerprint: "SHA256:abc", keyType: 1))
    }

    @Test
    func nonTeleportMatchingPinVerifies() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: false,
            fingerprint: "SHA256:abc",
            keyType: 1,
            knownFingerprint: "SHA256:abc",
            hostKeyBlob: Data(),
            expectedPrincipals: [],
            teleportHostCACheckingKeys: [],
            now: Self.validNow
        )
        #expect(decision == .verified(refreshPin: false))
    }

    @Test
    func nonTeleportChangedKeyIsRejected() {
        let decision = HostKeyTrustPolicy.decide(
            isTeleport: false,
            fingerprint: "SHA256:new",
            keyType: 1,
            knownFingerprint: "SHA256:old",
            hostKeyBlob: Data(),
            expectedPrincipals: [],
            teleportHostCACheckingKeys: [],
            now: Self.validNow
        )
        #expect(decision == .rejectHostKeyVerification)
    }
}

#endif
