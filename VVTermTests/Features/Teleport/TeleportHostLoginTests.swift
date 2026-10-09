// SPDX-License-Identifier: MIT
//
//  TeleportHostLoginTests.swift
//  VVTermTests
//
//  Host-only coverage for the connect-time fail-closed route
//  (`SSHError+TeleportHostLogin`'s `TeleportHostLoginFailureRoute`): a failed
//  principal resolution must clear the credential (readiness flips back so the
//  setup sheet is reachable) and surface the named connect error.
//
//  The package owns the resolver / selection / reflection suites
//  (`TeleportCoreTests`); this file keeps only the host route that maps the
//  package failure into `SSHError`.
//

import Foundation
import Testing
import TeleportCore
import TeleportTesting
@testable import VVTerm

struct TeleportHostLoginTests {

    // MARK: - Fail-closed route

    /// The connect-time fail-closed route must clear the credential (readiness
    /// flips to `.needsBootstrap`, so the setup sheet with the picker becomes
    /// reachable again) and return the named connect error.
    @Test @MainActor
    func failClosedRouteClearsTheCredentialAndReturnsTheNamedError() async {
        let keyRing = MockTeleportKeyRing()
        let clusterId = UUID()
        keyRing.seed(
            clusterId: clusterId,
            fixture: MockTeleportKeyRing.Fixture(
                hasBootstrapCert: true,
                hasSEPKey: true,
                certValidBefore: Date().addingTimeInterval(3600),
                credentialID: Data([1, 2, 3, 4]),
                userHandle: Data("user-handle".utf8),
                deviceName: "test-device"
            )
        )
        #expect(keyRing.credentials[clusterId] != nil)

        let error = await TeleportHostLoginFailureRoute.clearAndFail(
            .ambiguousPrincipalSet(["deploy", "root"]),
            store: keyRing,
            clusterId: clusterId
        )

        #expect(
            keyRing.credentials[clusterId] == nil,
            "the fail-closed route must clear the credential so setup is reachable again"
        )
        guard case .teleportHostLoginUnresolvable(let failure) = error else {
            Issue.record("expected .teleportHostLoginUnresolvable, got \(error)")
            return
        }
        #expect(failure == .ambiguousPrincipalSet(["deploy", "root"]))
    }
}
