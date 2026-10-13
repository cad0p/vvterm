// SPDX-License-Identifier: MIT
//
//  TeleportPhaseTransitionWaitBudgetPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #444: the scheduled shard-3 class
//  `VVTermUITests/Features/Teleport/TeleportPhaseTransitionUITests.swift`
//  must keep its repaired wait/tap contract, and the harness
//  `VVTerm/App/iOS/TeleportPhaseChainUITestHarness+iOS.swift` must keep the
//  tap-specific gate-release observable the class asserts.
//
//  WHY SOURCE PINS: #444 is a host-state AX-stall flake (I1: the "Failed to
//  determine hittability ... Activation point invalid" record lives inside
//  `-[XCUIElement isHittable]`; I2: a 5 s predicate raced the AX hierarchy).
//  The repair is structural — no `isHittable`, no
//  `XCTNSPredicateExpectation`, all 9 taps on a
//  `coordinate(withNormalizedOffset:)` chain, a 30 s calibrated carrier
//  budget, and a state-gated gate-release counter — but none of it is a
//  property the compiler can check. A future edit can silently reintroduce
//  an `isHittable` read, a bare `element.tap()`, a short carrier budget or a
//  non-tap-specific counter and re-open the flake with green tests. These
//  pins make that a red test (the #400
//  `ServerNavigationUITestsWaitBudgetPinsTests` idiom).
//
//  WHAT IS PINNED (7 properties; the #444 plan §5 list):
//    1. class-scoped: no `isHittable`, no `XCTNSPredicateExpectation`;
//    2. `axWaitBudget` is the only `TimeInterval` constant and its literal is
//       30; the only call-site `budget:` arguments are the five frozen
//       non-carrier probes at their pre-existing 5 s (the A1 corrected scope
//       rule), and a helper's own `budget:` tokens are its signature plus
//       `tapControl`'s delegated existence wait;
//    3. per wait helper: the deadline is textually bound to `budget`, the
//       query is fresh INSIDE the loop, the pause is a `RunLoop` run (any
//       value — 0.1 → 0.25 is an accepted variant), there is no
//       `Thread.sleep` / `usleep` / `while true`, and the only numeric
//       interval is the settle (3, tapControl) plus the poll pause;
//    4. per wait helper: the exact normalized `XCTFail` call carries every
//       unconditional payload key (and only those);
//    5. every `.tap()` is on a `coordinate(withNormalizedOffset:` chain and
//       `exists` immediately precedes every `.frame` read;
//    6. the three scheduled `func test…` names are present exactly once each
//       and the test-body anchor count is 3 (a 4th `func test` reds);
//    7. the harness A3 observable: the exact state-gated action expression,
//       the `…gateReleases` identifier, and the label rendered as a direct
//       child of the sheet `ZStack` (not inside `PhaseChainGateOverlay`),
//       unconditionally.
//
//  SLICE RULE (plan §5 v4, CL-4): helpers anchor on
//  `(?m)^    private func (\w+)`, test bodies on `(?m)^    func (test\w+)\(`;
//  a slice terminates at the EARLIEST of the next helper anchor, the next
//  test-body anchor, or the column-0 `}`. The v3 rule (next helper or `}`)
//  swallowed all three test bodies into the last helper's slice, so any
//  `contains` property could be satisfied by test-body content; the
//  purity check (`func test` / `XCTAssert` inside a helper slice) and the
//  terminator close that. Fail closed if the helper set, the test set, the
//  all-`func` reconciliation or the anchor count drifts.
//
//  FORMATTING HEURISTIC, NOT A PROOF. These pins parse Swift as text. Honest
//  defeat list: a computed-key re-expression (`String("isHittable")`,
//  reflection, KVC) or an `XCTWaiter` re-expression of the recorded read; a
//  string-literal decoy that satisfies a token check; the runtime snapshot
//  freshness no source pin can see; the exists-guarded `.frame`/`.label`
//  reads that remain racy at runtime (#444 §8); a payload branch reachable
//  only at runtime; a coherent code+pin edit (inherent to update-on-purpose
//  pins); and, for property 6, the `WorkflowShardSplitPinsTests` overlap
//  (that suite is the scheduling authority).
//
//  THIS IS THE SEVENTH COPY of the `repositoryRoot()` +
//  `VVTERM_PINS_SOURCE_ROOT` source-scan idiom (after
//  `ServerNavigationUITestsWaitBudgetPinsTests`,
//  `TerminalKeyboardCoordinatorPinsTests`,
//  `TeleportCredentialPairPinsTests` and the workflow pin family).
//  Extraction is DELIBERATELY DEFERRED: this pin's per-helper slice scanner
//  (anchor sets, earliest-of-three terminator, numeric allowlists) is
//  scanner-local, and refactoring six pin suites would be an unrelated risk
//  on a flake fix. Re-evaluate when a sixth Swift-source pin needs the same
//  scanner, or when this file passes ~400 lines.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment (a
//  plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct TeleportPhaseTransitionWaitBudgetPinsTests {

    // MARK: - Frozen sets

    private static let classPath =
        "VVTermUITests/Features/Teleport/TeleportPhaseTransitionUITests.swift"
    private static let harnessPath =
        "VVTerm/App/iOS/TeleportPhaseChainUITestHarness+iOS.swift"

    /// The frozen `private func` set, in file order. The all-`func`
    /// reconciliation below also reds a NON-private helper, so this is the
    /// helper-set freeze and the slice map in one.
    private static let helperNames = [
        "launch",
        "attachScreenshot",
        "waitForElement",
        "waitForLabel",
        "tapControl",
    ]

    /// The three scheduled `func test…` names, in file order.
    private static let testNames = [
        "testPhase1BootstrapSuccess_transitionsToRegistrationSheet",
        "testPhase1BootstrapSuccess_doesNotReRunBootstrap",
        "testPhase2RegistrationSuccess_transitionsToLoginSheet",
    ]

    /// The wait helpers that must carry the A1 poll contract. `tapControl` is
    /// checked separately (delegated existence wait + settle + coordinate
    /// tap).
    private static let pollingHelpers = ["waitForElement", "waitForLabel"]

    /// The five frozen non-carrier probe call sites, each passing the
    /// pre-existing 5 s (A1 corrected scope; CL-2). The multiset is frozen so
    /// a carrier site that starts passing a budget reds.
    private static let probeBudgetLiterals = ["5", "5", "5", "5", "5"]

    /// `budget:` token counts per helper slice: the signature default and,
    /// for `tapControl`, the delegated existence wait.
    private static let helperBudgetTokens: [String: Int] = [
        "launch": 0,
        "attachScreenshot": 0,
        "waitForElement": 1,
        "waitForLabel": 1,
        "tapControl": 2,
    ]

    /// The exact normalized failure call per wait helper (CL-13's exact
    /// needle and the unconditional payload keys). Kept as raw strings so the
    /// `\(…)` interpolations are literal text.
    private static let expectedFailureCalls: [String: String] = [
        "waitForElement":
            #"XCTFail( "\(reason) — attempts=\(attempts) elapsed=\(elapsedMs)ms budget=\(budget)s identifier=\(identifier) lastExists=\(lastExists) app state=\(app.state.rawValue)""#,
        "waitForLabel":
            #"XCTFail( "\(reason) — attempts=\(attempts) elapsed=\(elapsedMs)ms budget=\(budget)s identifier=\(identifier) needle=\(needle) lastExists=\(lastExists) label=\(lastLabel) labelReadMs=\(lastLabelReadMs) app state=\(app.state.rawValue)""#,
    ]

    private static let gateReleasesIdentifier = "vvterm.teleport.phaseChainHarness.gateReleases"

    // MARK: - Property 1

    @Test
    func property1NoHittabilityReadAndNoPredicateExpectation() throws {
        let normalized = Self.collapse(try Self.strippingComments(Self.source(Self.classPath)))
        #expect(
            !normalized.contains("isHittable"),
            "the class must not read `isHittable`: the #444 I1 record lives inside the getter's `hitPoint:` path — re-derive this pin (issue #444)"
        )
        #expect(
            !normalized.contains("XCTNSPredicateExpectation"),
            "the class must not use `XCTNSPredicateExpectation`: its predicate and a direct `isHittable` read are the same recorded path — re-derive this pin (issue #444)"
        )
    }

    // MARK: - Property 2

    @Test
    func property2TheBudgetIsDeclaredOnceAndCallSitesAreFrozen() throws {
        let slices = try Self.classSlices()

        let constants = Self.timeIntervalConstants(in: slices.normalized)
        #expect(
            constants.count == 1 && constants[0].0 == "axWaitBudget" && constants[0].1 == "30",
            "`axWaitBudget` must be the only `TimeInterval` constant, declared once with the literal 30 (any second constant — suffixed or not — reds; the unsafe direction is a silent 30→5 edit re-opening #444) — found \(constants) (issue #444)"
        )

        let testBodyText = slices.testBodies.joined(separator: "\n")
        let budgetTokens = testBodyText.components(separatedBy: "budget:").count - 1
        let budgetLiterals = Self.budgetLiterals(in: testBodyText)
        #expect(
            budgetTokens == Self.probeBudgetLiterals.count,
            "exactly \(Self.probeBudgetLiterals.count) call-site `budget:` arguments are allowed (the non-carrier probes); a carrier site that passes a budget reds — found \(budgetTokens) `budget:` tokens (issue #444)"
        )
        #expect(
            budgetLiterals.sorted() == Self.probeBudgetLiterals.sorted(),
            "the only call-site `budget:` arguments must be the five frozen 5 s non-carrier probes — found \(budgetLiterals.sorted()) (issue #444)"
        )

        for name in Self.helperNames {
            let body = slices.helperBodies[name] ?? ""
            let tokens = body.components(separatedBy: "budget:").count - 1
            #expect(
                tokens == Self.helperBudgetTokens[name],
                "\(name) must carry exactly \(Self.helperBudgetTokens[name] ?? -1) `budget:` token(s) (its signature default, plus `tapControl`'s delegated existence wait) — found \(tokens) (issue #444)"
            )
        }
    }

    // MARK: - Property 3

    @Test
    func property3TheWaitHelpersPollWithABudgetBoundDeadline() throws {
        let slices = try Self.classSlices()

        for name in Self.pollingHelpers {
            let body = slices.helperBodies[name] ?? ""
            #expect(
                body.contains("let deadline = Date().addingTimeInterval(budget)"),
                "\(name) must bind its deadline textually to `budget` (`let deadline = Date().addingTimeInterval(budget)`) — a hardcoded deadline reds even when the literal equals an allowed poll value (CL-9) (issue #444)"
            )
            let whileRange = try #require(
                body.range(of: "while Date() < deadline"),
                "\(name) must poll in a `while Date() < deadline` loop (issue #444)"
            )
            let queryRange = try #require(
                body.range(of: "[identifier]", range: whileRange.upperBound..<body.endIndex),
                "\(name) must construct the query fresh INSIDE the loop (`[identifier]` after the loop token) — a hoisted/captured element read reds (issue #444)"
            )
            #expect(
                body.range(
                    of: "RunLoop.current.run(until: Date().addingTimeInterval(",
                    range: queryRange.upperBound..<body.endIndex
                ) != nil,
                "\(name) must pause with a `RunLoop` run after the in-loop query — a fixed sleep reds (issue #444)"
            )
            for forbidden in ["Thread.sleep", "usleep", "while true"] {
                #expect(
                    !body.contains(forbidden),
                    "\(name) must not contain `\(forbidden)` (issue #444)"
                )
            }
            for interval in Self.numericIntervals(in: body) {
                #expect(
                    body.contains("RunLoop.current.run(until: Date().addingTimeInterval(\(interval)))"),
                    "\(name): numeric interval \(interval) outside the poll-pause position is not allowed (the settle is the only other numeric interval, and only in tapControl) (issue #444)"
                )
            }
            let strayNumerics = Set(Self.numericLiteralsOutsideIntervals(in: body)).subtracting(["0", "1", "1000"])
            #expect(
                strayNumerics.isEmpty,
                "\(name): unexpected numeric literal(s) \(strayNumerics.sorted()) — the attempt counter (0/1) and the `labelReadMs` conversion (1000) are the only allowed non-interval numerics (issue #444)"
            )
        }

        let tap = slices.helperBodies["tapControl"] ?? ""
        #expect(
            tap.contains("waitForElement(") && tap.contains("budget: budget"),
            "`tapControl` must delegate its existence wait to `waitForElement` with `budget: budget` (issue #444)"
        )
        #expect(
            tap.contains("let settleDeadline = Date().addingTimeInterval(3)"),
            "`tapControl` must keep the bounded 3 s frame settle (`let settleDeadline = Date().addingTimeInterval(3)`) — the stop rule keeps this value (issue #444)"
        )
        let settleRange = try #require(
            tap.range(of: "while Date() < settleDeadline"),
            "`tapControl` must poll the settle in a `while Date() < settleDeadline` loop (issue #444)"
        )
        let settleQueryRange = try #require(
            tap.range(of: "[identifier]", range: settleRange.upperBound..<tap.endIndex),
            "`tapControl` must construct the query fresh INSIDE the settle loop (issue #444)"
        )
        #expect(
            tap.range(
                of: "RunLoop.current.run(until: Date().addingTimeInterval(",
                range: settleQueryRange.upperBound..<tap.endIndex
            ) != nil,
            "`tapControl` must pause with a `RunLoop` run after the in-loop query (issue #444)"
        )
        for forbidden in ["Thread.sleep", "usleep", "while true"] {
            #expect(
                !tap.contains(forbidden),
                "`tapControl` must not contain `\(forbidden)` (issue #444)"
            )
        }
        for interval in Self.numericIntervals(in: tap) {
            #expect(
                interval == "3" || tap.contains("RunLoop.current.run(until: Date().addingTimeInterval(\(interval)))"),
                "`tapControl`: numeric interval \(interval) outside the settle/poll positions is not allowed (issue #444)"
            )
        }
        let tapStrayNumerics = Set(Self.numericLiteralsOutsideIntervals(in: tap)).subtracting(["0", "0.5"])
        #expect(
            tapStrayNumerics.isEmpty,
            "`tapControl`: unexpected numeric literal(s) \(tapStrayNumerics.sorted()) — the frame `> 0` guards and the normalized offset (0.5) are the only allowed non-interval numerics (issue #444)"
        )
    }

    // MARK: - Property 4

    @Test
    func property4TheFailurePayloadsCarryTheirKeys() throws {
        let slices = try Self.classSlices()
        let sharedKeys = ["attempts=", "elapsed=", "budget=", "identifier=", "lastExists=", "app state="]
        let labelKeys = ["needle=", "label=", "labelReadMs="]

        for name in Self.pollingHelpers {
            let body = slices.helperBodies[name] ?? ""
            let expected = Self.expectedFailureCalls[name] ?? ""
            #expect(
                body.contains(expected),
                "\(name)'s exact normalized failure call changed — the single-owner payload is `\(expected)` (issue #444)"
            )
            let failRange = try #require(
                body.range(of: "XCTFail("),
                "\(name) must assert internally via `XCTFail` (issue #444)"
            )
            let keys = name == "waitForLabel" ? sharedKeys + labelKeys : sharedKeys
            for key in keys {
                let keyRange = try #require(
                    body.range(of: key),
                    "\(name)'s failure payload must carry `\(key)` unconditionally (issue #444)"
                )
                #expect(
                    keyRange.lowerBound > failRange.lowerBound,
                    "\(name): `\(key)` must be inside the `XCTFail` payload, not a pre-payload token (issue #444)"
                )
            }
        }
    }

    // MARK: - Property 5

    @Test
    func property5EveryTapIsACoordinateTapAndEveryFrameReadIsGuarded() throws {
        let raw = try Self.strippingComments(Self.source(Self.classPath))
        let lines = raw.components(separatedBy: "\n")
        var tapCount = 0
        var tapViolations: [String] = []
        var frameViolations: [String] = []
        var previousNonEmpty = ""
        for line in lines {
            if line.contains(".tap()") {
                tapCount += 1
                if !line.contains("coordinate(withNormalizedOffset:") {
                    tapViolations.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            if line.contains(".frame") {
                let guarded = line.contains(".exists") || previousNonEmpty.contains(".exists")
                if !guarded {
                    frameViolations.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                previousNonEmpty = line
            }
        }
        #expect(
            tapCount >= 1,
            "the class must contain at least one `.tap()` (the `tapControl` coordinate tap) — found 0; a replaced tap path is a pin update (issue #444)"
        )
        #expect(
            tapViolations.isEmpty,
            "every `.tap()` must be on a `coordinate(withNormalizedOffset:` chain — bare element taps red (the #444 I1 record path) — found \(tapViolations) (issue #444)"
        )
        #expect(
            frameViolations.isEmpty,
            "every `.frame` read must be immediately preceded by an `exists` guard — found \(frameViolations) (issue #444)"
        )
    }

    // MARK: - Property 6

    @Test
    func property6TheScheduledTestNamesAndAnchorsAreFrozen() throws {
        let slices = try Self.classSlices()
        #expect(
            slices.testOrder == Self.testNames,
            "the 3 scheduled `func test…` names (in file order) are frozen — found \(slices.testOrder); a rename is a pin + workflow + fixture update (issue #444)"
        )
        #expect(
            slices.testOrder.count == 3,
            "the test-body anchor count must be exactly 3 (a 4th `func test…` reds this count) — found \(slices.testOrder.count) (issue #444)"
        )
    }

    // MARK: - Property 7 (harness A3 observable)

    @Test
    func property7TheGateReleaseObservableIsStateGatedAndAlwaysRendered() throws {
        let raw = try Self.strippingComments(Self.source(Self.harnessPath))
        let normalized = Self.collapse(raw)

        #expect(
            normalized.contains("if coordinator.state == .awaitingApproval, coordinator.releaseApproval() { gateReleases += 1 }"),
            "the gate button's action must be state-gated (`if coordinator.state == .awaitingApproval, coordinator.releaseApproval() { gateReleases += 1 }`) — an unconditional increment is not tap-specific (CL-1/CL-5) (issue #444)"
        )
        #expect(
            normalized.contains(#"Text("gateReleases: \(gateReleases)")"#),
            "the harness must render an always-present `Text(\"gateReleases: \\(gateReleases)\")` (issue #444)"
        )
        let identifierOccurrences = normalized.components(separatedBy: Self.gateReleasesIdentifier).count - 1
        #expect(
            identifierOccurrences == 1,
            "exactly one element may carry `\(Self.gateReleasesIdentifier)` — found \(identifierOccurrences); a decoy with the same identifier makes the class's resolution ambiguous (CL-5/CL-11) (issue #444)"
        )

        let sheetRange = try #require(
            raw.range(of: ".sheet(isPresented: $presentingSheet)"),
            "the harness sheet closure could not be located — re-derive this pin (issue #444)"
        )
        let zstackRange = try #require(
            raw.range(of: "ZStack(alignment: .bottom)", range: sheetRange.upperBound..<raw.endIndex),
            "the sheet closure's `ZStack(alignment: .bottom)` could not be located (issue #444)"
        )
        let identifierRange = try #require(
            raw.range(of: Self.gateReleasesIdentifier, range: zstackRange.upperBound..<raw.endIndex),
            "the gateReleases label must be a direct child of the sheet ZStack (after the ZStack, before any struct) (issue #444)"
        )
        let overlayRange = try #require(
            raw.range(of: "private struct PhaseChainGateOverlay"),
            "`PhaseChainGateOverlay` could not be located — re-derive this pin (issue #444)"
        )
        #expect(
            identifierRange.lowerBound < overlayRange.lowerBound,
            "the gateReleases label must be rendered on the presented surface (the sheet ZStack), NOT inside `PhaseChainGateOverlay` (whose body is state-gated and would take the label with it) (CL-5) (issue #444)"
        )
        let overlaySlice = String(raw[overlayRange.lowerBound..<raw.endIndex])
        #expect(
            !overlaySlice.contains(#"Text("gateReleases:"#),
            "`PhaseChainGateOverlay` must not own the gateReleases label (issue #444)"
        )

        // The label's own declaration: the identifier belongs to the
        // gateReleases Text's modifier chain, and the element is not wrapped
        // in an `if` (always rendered, not state-gated).
        let labelTextRange = try #require(
            raw.range(of: #"Text("gateReleases: \(gateReleases)")"#),
            "the gateReleases `Text` declaration could not be located (issue #444)"
        )
        #expect(
            labelTextRange.lowerBound < identifierRange.lowerBound,
            "the `gateReleases` identifier must belong to the `Text(\"gateReleases: \\(gateReleases)\")` element (issue #444)"
        )
        let between = String(raw[labelTextRange.upperBound..<identifierRange.lowerBound])
        #expect(
            !between.contains("Text("),
            "no second `Text` may intervene between the gateReleases label and its identifier (issue #444)"
        )

        let lines = raw.components(separatedBy: "\n")
        var labelLineIndex: Int?
        for (index, line) in lines.enumerated() where line.contains(#"Text("gateReleases: \(gateReleases)")"#) {
            labelLineIndex = index
        }
        let lineIndex = try #require(labelLineIndex, "the gateReleases `Text` line could not be located (issue #444)")
        var previous = lineIndex - 1
        while previous >= 0, lines[previous].trimmingCharacters(in: .whitespaces).isEmpty {
            previous -= 1
        }
        if previous >= 0 {
            let previousLine = lines[previous]
            #expect(
                !(previousLine.contains("if ") && previousLine.trimmingCharacters(in: .whitespaces).hasSuffix("{")),
                "the gateReleases label must be rendered unconditionally — it must not be wrapped in an `if` (an always-0 counter would otherwise look released) (CL-5) (issue #444)"
            )
        }
    }

    // MARK: - Slice scanner (fail-closed)

    private struct Anchor {
        let name: String
        let start: String.Index
        let bodyStart: String.Index
    }

    private struct ClassSlices {
        let normalized: String
        let helperOrder: [String]
        let helperBodies: [String: String]
        let testOrder: [String]
        let testBodies: [String]
    }

    /// Comment-strip the class, freeze the helper/test/`func` anchor sets, and
    /// slice each helper at the earliest of the next helper, the next test
    /// body, or the column-0 `}`. Fail closed on any drift, and on a helper
    /// slice that contains test-body content.
    private static func classSlices() throws -> ClassSlices {
        let raw = Self.strippingComments(Self.source(Self.classPath))
        let helpers = try anchors(pattern: #"(?m)^    private func (\w+)"#, in: raw)
        let tests = try anchors(pattern: #"(?m)^    func (test\w+)\("#, in: raw)
        let closers = try anchors(pattern: #"(?m)^(\})"#, in: raw)

        let helperOrder = helpers.map(\.name)
        guard helperOrder == helperNames else {
            throw PinFailure(
                "the class's `private func` set changed: expected \(helperNames), found \(helperOrder) — a new/removed/renamed helper is a pin update (issue #444)"
            )
        }
        let testOrder = tests.map(\.name)
        guard testOrder == testNames else {
            throw PinFailure(
                "the class's `func test…` set changed: expected \(testNames), found \(testOrder) — the 3 scheduled names are frozen (issue #444)"
            )
        }
        let allFuncs = try anchors(pattern: #"(?m)^    (?:private )?func (\w+)"#, in: raw).map(\.name)
        guard allFuncs.sorted() == (helperNames + testNames).sorted() else {
            throw PinFailure(
                "a `func` outside the frozen helper/test sets is at class scope: \(allFuncs) — a non-private helper or a 4th `func test…` reds the anchor-set freeze (issue #444)"
            )
        }

        var boundaries: [String.Index] = helpers.map(\.start) + tests.map(\.start) + closers.map(\.start)
        boundaries.sort()

        func body(after index: String.Index) -> String {
            let next = boundaries.first { $0 > index } ?? raw.endIndex
            return Self.collapse(String(raw[index..<next]))
        }

        var helperBodies: [String: String] = [:]
        for (anchor, sourceAnchor) in zip(helperOrder, helpers) {
            let slice = body(after: sourceAnchor.bodyStart)
            guard !slice.contains("func test"), !slice.contains("XCTAssert") else {
                throw PinFailure(
                    "the \(anchor) slice contains test-body content (`func test`/`XCTAssert`) — the slice terminator must stop at the next helper, the next test body or the column-0 `}` (CL-4) (issue #444)"
                )
            }
            helperBodies[anchor] = slice
        }
        var testBodies: [String] = []
        for sourceAnchor in tests {
            testBodies.append(body(after: sourceAnchor.bodyStart))
        }

        return ClassSlices(
            normalized: collapse(raw),
            helperOrder: helperOrder,
            helperBodies: helperBodies,
            testOrder: testOrder,
            testBodies: testBodies
        )
    }

    private static func anchors(pattern: String, in source: String) throws -> [Anchor] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let fullRange = Range(match.range, in: source),
                  let nameRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return Anchor(name: String(source[nameRange]), start: fullRange.lowerBound, bodyStart: fullRange.upperBound)
        }
    }

    // MARK: - Extractors

    private static func timeIntervalConstants(in source: String) -> [(String, String)] {
        let pattern = #"(?<![A-Za-z0-9])let (\w+): TimeInterval = ([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let literalRange = Range(match.range(at: 2), in: source) else {
                return nil
            }
            return (String(source[nameRange]), String(source[literalRange]))
        }
    }

    private static func budgetLiterals(in source: String) -> [String] {
        matches(pattern: #"budget: ([0-9.]+)"#, in: source)
    }

    /// Numeric literals in `addingTimeInterval(<literal>)` positions.
    private static func numericIntervals(in source: String) -> [String] {
        matches(pattern: #"addingTimeInterval\(([0-9.]+)\)"#, in: source)
    }

    /// Numeric literals outside `addingTimeInterval(…)` positions.
    private static func numericLiteralsOutsideIntervals(in source: String) -> [String] {
        let withoutIntervals = source.replacingOccurrences(
            of: #"addingTimeInterval\([^)]*\)"#,
            with: "addingTimeInterval()",
            options: .regularExpression
        )
        return matches(pattern: #"(?<![A-Za-z0-9_.])[0-9]+(?:\.[0-9]+)?"#, in: withoutIntervals)
    }

    private static func matches(pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[captureRange])
        }
    }

    private static func collapse(_ source: String) -> String {
        source.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    // MARK: - Source helpers
    //
    // Deliberately duplicated per pin suite (the #280 pattern): the suites
    // must stay independently revertable, so they share no test-target helper
    // file.

    private static func source(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the pinned files mutated. The measured-working form is
        // `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported into
        // xcodebuild's own environment (the `TEST_RUNNER_` prefix is consumed
        // by the test runner and forwarded without it).
        if let override = ProcessInfo.processInfo.environment["VVTERM_PINS_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
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
        throw PinFailure(
            "could not locate the repository root (no VVTerm.xcodeproj above \(#filePath)) — re-derive this pin"
        )
    }

    /// A comment-stripped copy of `source`: characters inside `//` line
    /// comments and nested `/* … */` block comments become spaces; newlines
    /// are preserved, so slice anchors still resolve. String contents are
    /// copied verbatim. Duplicated from the merged pin suites so each family's
    /// pin file is self-contained and reverts independently.
    private static func strippingComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var blockCommentDepth = 0
        var inLineComment = false
        var stringDelimiter: Int? = nil  // 1 for `"…"`, 3 for `"""…"""`
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index += 1
                continue
            }
            if blockCommentDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockCommentDepth += 1
                    result.append("  ")
                    index += 2
                } else if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockCommentDepth -= 1
                    result.append("  ")
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            if let delimiter = stringDelimiter {
                result.append(character)
                index += 1
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\" {
                    escaped = true
                    continue
                }
                if delimiter == 1, character == "\"" {
                    stringDelimiter = nil
                    continue
                }
                if delimiter == 3,
                   character == "\"",
                   index + 1 < characters.count,
                   characters[index] == "\"",
                   characters[index + 1] == "\"" {
                    result.append("\"\"")
                    index += 2
                    stringDelimiter = nil
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                inLineComment = true
                result.append("  ")
                index += 2
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                blockCommentDepth = 1
                result.append("  ")
                index += 2
                continue
            }
            if character == "\"" {
                if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                    stringDelimiter = 3
                    result.append("\"\"\"")
                    index += 3
                } else {
                    stringDelimiter = 1
                    result.append("\"")
                    index += 1
                }
                continue
            }
            result.append(character)
            index += 1
        }
        return result
    }

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }
}
