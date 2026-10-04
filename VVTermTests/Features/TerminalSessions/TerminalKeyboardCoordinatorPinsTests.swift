// SPDX-License-Identifier: MIT
//
//  TerminalKeyboardCoordinatorPinsTests.swift
//  VVTermTests
//
//  Body-scoped source pins for the seven #359 presentation-verification sites
//  in `TerminalKeyboardCoordinatorTests.swift` (issue #359).
//
//  WHY SOURCE PINS: the sites raced the coordinator's own 1.0 s presentation-
//  verification deadline with fixed 1.1 s sleeps, so a descheduled runner could
//  assert before the pass completed. The replacements observe the pass
//  (`keyboardUITestAwaitPresentationVerification` via the bounded test-side
//  helpers) or, for the no-live-pass sites, the synchronous cancellation
//  (`!keyboardUITestPresentationVerificationPending`). These pins keep the
//  observations in place per body, following the #358 precedent
//  (`TeleportAgentForwardingPinsTests.eofRetirementTestObservesTheStoreInsteadOfSleeping`).
//
//  WHAT IS PINNED: for each named test body (`func <name>` → the next
//  `\n    @Test`), the body must contain the site's observation token and must
//  not contain `Task.sleep(`. Sites 2 and 3 share one test body
//  (`sceneActivationRepairsAcquiredSessionOnceWhenKeyboardNeverPresents`),
//  which must carry both observation tokens.
//
//  DEFEAT LIST (known/measured limits): a computed duration (`Task.sleep`
//  spelled via a variable), `Thread.sleep`/`usleep`, a wait hidden in a helper
//  the body only calls (the accepted limit of a body-scoped pin), body-boundary
//  drift (the `\n    @Test` sentinel changing), and a weakened but still
//  matched observation such as a helper call whose body was gutted. A tripwire,
//  not a proof. The `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` override lets a
//  counterfactual run point the pin at a mutated tree.

import Foundation
import Testing

@testable import VVTerm

struct TerminalKeyboardCoordinatorPinsTests {

    private struct Pin {
        let site: Int
        let testName: String
        /// Token that proves the site observes the pass (or its cancellation).
        let observation: String
    }

    /// The seven #359 sites. Sites 2 and 3 share one test body.
    private static let pins: [Pin] = [
        Pin(
            site: 1,
            testName: "appSwitchReleasesResponderWhilePreservingTypingIntent",
            observation: "!coordinator.keyboardUITestPresentationVerificationPending"
        ),
        Pin(
            site: 2,
            testName: "sceneActivationRepairsAcquiredSessionOnceWhenKeyboardNeverPresents",
            observation: "awaitOnePresentationVerificationPass"
        ),
        Pin(
            site: 3,
            testName: "sceneActivationRepairsAcquiredSessionOnceWhenKeyboardNeverPresents",
            observation: "drainPresentationVerification"
        ),
        Pin(
            site: 4,
            testName: "terminalReplacementReconcilesNewOwnerAndCancelsOldVerification",
            observation: "!coordinator.keyboardUITestPresentationVerificationPending"
        ),
        Pin(
            site: 5,
            testName: "routeModalDeactivationReleasesInputAndCancelsPresentationVerification",
            observation: "!coordinator.keyboardUITestPresentationVerificationPending"
        ),
        Pin(
            site: 6,
            testName: "contentProtectionRoundTripReplaysSceneActivationRecovery",
            observation: "drainPresentationVerification"
        ),
        Pin(
            site: 7,
            testName: "missingInitialKeyboardSuppressesAccessoryAfterPresentationSettles",
            observation: "drainPresentationVerification"
        ),
    ]

    @Test
    func presentationVerificationSitesObserveThePassInsteadOfSleeping() throws {
        let source = try source(
            "VVTermTests/Features/TerminalSessions/TerminalKeyboardCoordinatorTests.swift"
        )

        for pin in Self.pins {
            // Positive control: the anchor must resolve uniquely before the
            // body slice can mean anything.
            let anchor = "func \(pin.testName)("
            #expect(
                source.components(separatedBy: anchor).count == 2,
                "site \(pin.site): \(pin.testName) must appear exactly once in the coordinator tests"
            )
            let header = try #require(source.range(of: anchor))
            let rest = source[header.lowerBound...]
            let end = try #require(
                rest.range(
                    of: "\n    @Test",
                    range: rest.index(after: rest.startIndex)..<rest.endIndex
                ),
                "site \(pin.site): could not resolve the body end for \(pin.testName)"
            )
            let body = rest[..<end.lowerBound]

            #expect(
                body.contains(pin.observation),
                "site \(pin.site) (\(pin.testName)) must observe the verification state via \(pin.observation.debugDescription)"
            )
            #expect(
                !body.contains("Task.sleep("),
                "site \(pin.site) (\(pin.testName)) must not race a fixed sleep"
            )
        }
    }

    // MARK: - Source helpers
    //
    // Deliberately duplicated per pin suite (the #280 pattern): the suites must
    // stay independently revertable, so they share no test-target helper file.

    private func repositoryRoot() -> URL {
        // Counterfactual hook: a mutation run points this at a copy of the
        // source with tokens removed. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed
        // by the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("VVTerm.xcodeproj").path
            ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
