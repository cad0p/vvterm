// SPDX-License-Identifier: MIT
//
//  TeleportHostLoginTests.swift
//  VVTermTests
//
//  Unit coverage for the pure Teleport SSH-username resolver (#262).
//
//  The resolver is the only writer of the Teleport SSH username. It must:
//    - use the stored login only when it is still a principal of the exact
//      certificate being sent;
//    - derive a login only for an exactly-one-principal certificate;
//    - fail closed (never guess, never send a non-principal) for an ambiguous
//      or empty principal set, or an unreadable certificate;
//    - filter internal (`-…`) principals before both paths, in certificate
//      wire order (tsh `Logins:` parity).
//

import Foundation
import Testing
@testable import VVTerm

struct TeleportHostLoginTests {

    // MARK: - Fixtures

    private func makeCert(
        keyID: String = "pier",
        principals: [String]
    ) -> OpenSSHCertificate {
        OpenSSHCertificate(
            certKeyType: "ssh-ed25519-cert-v01@openssh.com",
            nonce: Data([0, 1, 2, 3]),
            publicKeyBlob: Data([9, 9, 9]),
            serial: 1,
            certType: .user,
            keyID: keyID,
            validPrincipals: principals,
            validAfter: 0,
            validBefore: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970),
            criticalOptions: Data(),
            extensions: Data(),
            reserved: Data(),
            signatureKeyBlob: Data([7, 7]),
            signatureBlob: Data([8, 8]),
            signedData: Data([1, 2, 3])
        )
    }

    // MARK: - Stored login

    @Test
    func storedLoginIsUsedWhenItIsStillAPrincipal() {
        let cert = makeCert(principals: ["deploy", "root", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "root")
                == .success("root")
        )
    }

    @Test
    func storedLoginThatIsNoLongerAPrincipalFallsBackToASinglePrincipal() {
        let cert = makeCert(principals: ["deploy"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "old-login")
                == .success("deploy")
        )
    }

    @Test
    func storedLoginThatIsNoLongerAPrincipalFailsClosedWhenAmbiguous() {
        let cert = makeCert(principals: ["deploy", "root"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "old-login")
                == .failure(.ambiguousPrincipalSet(["deploy", "root"]))
        )
    }

    @Test
    func storedInternalPrincipalIsNeverUsed() {
        // A stored value that only matches an internal principal must not be
        // sent; the internal principal is filtered from the logins, so the
        // resolution falls through to the fallback.
        let cert = makeCert(principals: ["deploy", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "-teleport-internal-join")
                == .success("deploy")
        )
    }

    @Test
    func blankStoredLoginIsTreatedAsNoPreference() {
        let cert = makeCert(principals: ["deploy"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: "   ")
                == .success("deploy")
        )
    }

    // MARK: - Derived fallback

    @Test
    func singleNonInternalPrincipalIsDerived() {
        let cert = makeCert(principals: ["deploy", "-teleport-internal-join"])
        #expect(TeleportHostLogin.resolve(cert: cert, storedLogin: nil) == .success("deploy"))
    }

    @Test
    func multiplePrincipalsFailClosed() {
        let cert = makeCert(principals: ["deploy", "root", "-teleport-internal-join"])
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: nil)
                == .failure(.ambiguousPrincipalSet(["deploy", "root"]))
        )
    }

    @Test
    func noPrincipalsFailClosed() {
        #expect(
            TeleportHostLogin.resolve(cert: makeCert(principals: []), storedLogin: nil)
                == .failure(.noPrincipals)
        )
    }

    @Test
    func onlyInternalPrincipalsFailClosed() {
        #expect(
            TeleportHostLogin.resolve(
                cert: makeCert(principals: ["-teleport-internal-join"]),
                storedLogin: nil
            ) == .failure(.noPrincipals)
        )
    }

    @Test
    func principalOrderIsCertificateWireOrder() {
        let cert = makeCert(principals: ["first", "second", "third"])
        // Wire order matters for the ambiguous error (tsh `Logins:` parity).
        #expect(
            TeleportHostLogin.resolve(cert: cert, storedLogin: nil)
                == .failure(.ambiguousPrincipalSet(["first", "second", "third"]))
        )
        #expect(TeleportHostLogin.nonInternalPrincipals(of: cert) == ["first", "second", "third"])
    }

    // MARK: - Parse path

    @Test
    func parsesTheFixtureCertAndUsesItsPrincipal() {
        // The fixture cert (`user-cert-ed25519.pub`) carries one principal:
        // `alice`. A stored `alice` is used; a stored non-principal degrades to
        // the derived single principal.
        let certPEM = TeleportFixtureSupport.fixedIssuedUserCert
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: certPEM, storedLogin: "alice")
                == .success("alice")
        )
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: certPEM, storedLogin: "deploy")
                == .success("alice")
        )
    }

    @Test
    func unreadableCertificateFailsClosed() {
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: "not-a-certificate", storedLogin: "deploy")
                == .failure(.certificateUnreadable)
        )
        #expect(
            TeleportHostLogin.resolveUsername(certPEM: "", storedLogin: nil)
                == .failure(.certificateUnreadable)
        )
    }

    // MARK: - Setup picker initial selection

    @Test
    func initialSelectionPrefersAStillValidStoredLogin() {
        #expect(
            TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: "root") == "root"
        )
    }

    @Test
    func initialSelectionAutoSelectsASinglePrincipal() {
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy"], stored: nil) == "deploy")
    }

    @Test
    func initialSelectionRequiresAnExplicitPickForMultiplePrincipals() {
        // The CA's wire order must never be frozen silently.
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: nil) == nil)
        // A stored value that is no longer a principal is not a valid default
        // either: the fresh cert is ambiguous, so the user must pick.
        #expect(
            TeleportHostLogin.initialSelection(logins: ["deploy", "root"], stored: "old-login") == nil
        )
    }

    @Test
    func initialSelectionIgnoresBlankStoredValuesAndEmptyLogins() {
        #expect(TeleportHostLogin.initialSelection(logins: ["deploy"], stored: "   ") == "deploy")
        #expect(TeleportHostLogin.initialSelection(logins: [], stored: "deploy") == nil)
    }

    // MARK: - Failure descriptions

    @Test
    func failureDescriptionsAreUserFacingAndNameTheLoginsOnlyForAmbiguity() {
        #expect(TeleportHostLoginFailure.noPrincipals.errorDescription?.isEmpty == false)
        let ambiguous = TeleportHostLoginFailure.ambiguousPrincipalSet(["deploy", "root"])
        #expect(ambiguous.errorDescription?.contains("deploy, root") == true)
        #expect(TeleportHostLoginFailure.certificateUnreadable.errorDescription?.isEmpty == false)
    }

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
