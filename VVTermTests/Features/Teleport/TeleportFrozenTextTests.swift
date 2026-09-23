// SPDX-License-Identifier: MIT
//
//  TeleportFrozenTextTests.swift
//  VVTerm
//
//  Pins the user-visible text contracts of the Teleport error types and the
//  loopback listener's timing defaults. These strings reach the UI through
//  `error.localizedDescription` (the coordinators put them into
//  `TeleportBootstrapError`/`TeleportLoginError`), and
//  `TeleportRegistrationCoordinator` string-matches one of them, so a
//  reworded message is an observable behavior change — not a cosmetic one.
//

#if DEBUG
import Foundation
import XCTest
@testable import VVTerm

@MainActor
final class TeleportFrozenTextTests: XCTestCase {

    // MARK: - SignerError

    func testSignerError_textsAreFrozen() {
        XCTAssertEqual(SignerError.keyCreationFailed("boom").description, "key creation failed: boom")
        XCTAssertEqual(SignerError.keyNotFound.description, "credential not found")
        XCTAssertEqual(SignerError.signingFailed("boom").description, "signing failed: boom")
        XCTAssertEqual(SignerError.invalidPublicKey("boom").description, "invalid public key: boom")
    }

    /// `SignerError` must stay `LocalizedError`: `TeleportLoginCoordinator`
    /// classifies Face ID failures by string-matching `localizedDescription`,
    /// which is the generic NSError text for a `CustomStringConvertible`-only
    /// error.
    func testSignerError_localizedDescriptionCarriesTheDescription() {
        let error = SignerError.signingFailed("LAError: user canceled")
        XCTAssertEqual(error.localizedDescription, error.description)
    }

    // MARK: - BrowserMFAListenerError

    func testBrowserMFAListenerError_textsAreFrozen() {
        XCTAssertEqual(BrowserMFAListenerError.listenerFailed("boom").errorDescription, "listener failed: boom")
        XCTAssertEqual(BrowserMFAListenerError.notReady.errorDescription, "listener not ready")
        XCTAssertEqual(
            BrowserMFAListenerError.timedOut.errorDescription,
            "timed out waiting for browser MFA callback"
        )
        XCTAssertEqual(
            BrowserMFAListenerError.unauthenticatedCallback("boom").errorDescription,
            "unauthenticated callback payload: boom"
        )
        XCTAssertEqual(BrowserMFAListenerError.decodeFailed("boom").errorDescription, "decode failed: boom")
    }

    // MARK: - BrowserMFACeremonyError

    func testBrowserMFACeremonyError_textsAreFrozen() {
        XCTAssertEqual(BrowserMFACeremonyError.safariFailed("boom").errorDescription, "Safari presentation failed: boom")
        XCTAssertEqual(BrowserMFACeremonyError.listenerFailed("boom").errorDescription, "loopback listener failed: boom")
        XCTAssertEqual(
            BrowserMFACeremonyError.noBrowserMFAChallenge.errorDescription,
            "server did not return a BrowserMFAChallenge (is BrowserMFATSHRedirectURL set + does the user have a Browser WebAuthn device?)"
        )
    }

    /// `TeleportRegistrationCoordinator` falls back to string-matching the
    /// wrapped error for the first-device path. The match key must survive any
    /// future rewording of the diagnostic hint.
    func testNoBrowserMFAChallengeText_keepsTheCoordinatorMatchKey() {
        let text = BrowserMFACeremonyError.noBrowserMFAChallenge.errorDescription ?? ""
        XCTAssertTrue(
            text.contains("did not return a BrowserMFAChallenge"),
            "the coordinator's first-device fallback matches this substring: \(text)"
        )
    }

    // MARK: - HeadlessError

    func testHeadlessError_textsAreFrozen() {
        XCTAssertEqual(HeadlessError.transport("boom").errorDescription, "transport: boom")
        XCTAssertEqual(HeadlessError.http(status: 403, body: "denied").errorDescription, "HTTP 403: denied")
        XCTAssertEqual(HeadlessError.decode("boom").errorDescription, "decode: boom")
        XCTAssertEqual(HeadlessError.noCert.errorDescription, "no cert in response")
        XCTAssertEqual(HeadlessError.missingField("cert").errorDescription, "missing field: cert")
    }

    // MARK: - Listener contract defaults

    /// The wait must outlive the server's 180 s approval window; the socket
    /// windows and the admission cap bound the loopback surface.
    func testListenerContractDefaultsAreFrozen() {
        XCTAssertEqual(BrowserMFAListener.defaultWaitTimeout, 180)
        XCTAssertEqual(BrowserMFAListener.defaultReadTimeout, 10)
        XCTAssertEqual(BrowserMFAListener.defaultStartTimeout, 15)
        XCTAssertEqual(BrowserMFAListener.defaultMaxConcurrentConnections, 16)
    }

    /// Pins the wiring, not only the values: the init's default arguments must
    /// read the frozen statics. A literal (`timeout: TimeInterval = 1`) keeps
    /// `testListenerContractDefaultsAreFrozen` green while changing the
    /// effective default.
    func testListenerInitDefaultsReferenceTheFrozenStatics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportFrozenTextTests.swift
            .deletingLastPathComponent()  // Teleport/
            .deletingLastPathComponent()  // Features/
            .deletingLastPathComponent()  // VVTermTests/
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("VVTerm/Features/Teleport/Infrastructure/BrowserMFAListener.swift"),
            encoding: .utf8
        )
        for expression in [
            "timeout: TimeInterval = BrowserMFAListener.defaultWaitTimeout",
            "readTimeout: TimeInterval = BrowserMFAListener.defaultReadTimeout",
            "startTimeout: TimeInterval = BrowserMFAListener.defaultStartTimeout",
            "maxConcurrentConnections: Int = BrowserMFAListener.defaultMaxConcurrentConnections",
        ] {
            XCTAssertTrue(
                source.contains(expression),
                "the listener init must default through the frozen static: \(expression)"
            )
        }
    }

    // MARK: - Face ID error mapping

    /// Regression for the isolated-deinit abort (issue #206 class): releasing a
    /// MainActor-isolated class synchronously, outside a task context, takes
    /// the back-deployed isolated-deinit path and traps in
    /// `TaskLocal::StopLookupScope`. `TeleportWebAuthnBuilder` is the
    /// coordinator's default builder, so a synchronous test that constructs a
    /// coordinator aborts without the explicit `nonisolated deinit {}`.
    func testWebAuthnBuilderReleasesSynchronouslyWithoutTrapping() {
        let builder = TeleportWebAuthnBuilder()
        XCTAssertNotNil(builder as any TeleportWebAuthnBuilding)
    }

    /// `mapSignerError` classifies the signer failure by the localized text.
    /// This is the user-visible half of the `LocalizedError` conformance: with
    /// a generic NSError description every Face ID failure would collapse into
    /// `.faceIDUnavailable`.
    func testMapSignerError_classifiesCancelLockoutAndNotEnrolled() async {
        let coordinator = TeleportLoginCoordinator(
            httpClient: MockTeleportHTTPClient(),
            keyRing: MockTeleportKeyRing(),
            logging: AppTeleportLogging.shared
        )

        XCTAssertEqual(
            coordinator.mapSignerError(SignerError.signingFailed("LAError: user canceled")),
            .faceIDCancelled
        )
        XCTAssertEqual(
            coordinator.mapSignerError(SignerError.signingFailed("LAError: biometry lockout")),
            .faceIDUnavailable("Face ID is locked. Enter your passcode to unlock Face ID, then try again.")
        )
        XCTAssertEqual(
            coordinator.mapSignerError(SignerError.signingFailed("LAError: biometry not enrolled")),
            .faceIDUnavailable("Face ID isn't available. Set up Face ID in iOS Settings.")
        )

        // An unrecognized failure keeps the raw description rather than
        // masquerading as a specific Face ID state.
        guard case .faceIDUnavailable(let message) = coordinator.mapSignerError(
            SignerError.signingFailed("some other failure")
        ) else {
            return XCTFail("expected .faceIDUnavailable for an unrecognized signer failure")
        }
        XCTAssertTrue(message.contains("some other failure"))
    }
}

#endif
