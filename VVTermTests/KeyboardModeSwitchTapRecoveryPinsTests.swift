// SPDX-License-Identifier: MIT
//
//  KeyboardModeSwitchTapRecoveryPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #441: `TerminalKeyboardUITests`'
//  `tapModeSwitchAndWaitForSurface` and the keyboard harness'
//  `harnessMode=terminal|other` observable.
//
//  WHY SOURCE PINS: #441 is a host-state AX refusal — the mode-switch tap's
//  hit point could not be resolved (`Computed hit point {-1, -1} after
//  scrolling to visible`) while the AX frame was sane and onscreen, and the
//  retry repeated the identical element-tap mechanism. The repair is
//  structural: every attempt now dispatches a raw coordinate touch (no
//  `isHittable` read, no bare element tap), the retry is keyed on the
//  harness's `harnessMode=` marker, and the terminal assertion carries the
//  marker/frame/existence diagnostics. None of that is a property the
//  compiler can check — a future edit can silently restore the refused
//  mechanism, drop the marker keying or lose the diagnostics with green
//  tests. These pins make that a red test (the #400
//  `ServerNavigationUITestsWaitBudgetPinsTests` idiom).
//
//  WHAT IS PINNED (5 properties):
//    P1  the helper dispatches exactly one `.tap()` and it is the inline
//        `coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()`
//        — zero `isHittable` reads, zero bare `element.tap()`/`button.tap()`;
//    P2  the retry is marker-keyed, ordered and bounded: the attempt loop is
//        the literal `for attempt in 1...3`, the anchors appear in order
//        (marker capture before the coordinate tap -> marker-change predicate
//        -> bounded surface wait -> terminal assertion), the helper parses
//        exactly one boundary-safe `harnessMode=` prefix, the marker-change
//        predicate rejects a captured `unknown` baseline, the changed-marker
//        branch keeps the surface wait (`if surface.waitForExistence … {
//        return }` else `break` into the terminal assertion), and the helper
//        body holds exactly one `return`;
//    P3  the helper keeps exactly one terminal assertion and its message
//        carries `markerBefore=`, `markerAfter=`, `frame=` and `exists=`
//        (no `isHittable` token);
//    P4  the keyboard harness emits `harnessMode=` and the swallow witness
//        `swallowedModeTap=` in BOTH `diagnostics =` assignments
//        (`showsTerminal ? "terminal" : "other"` derivation), and the split
//        harness emits neither;
//    P5  the swallow launch literal appears exactly once per file (the
//        `launchKeyboardHarness` writer and the harness reader), the writer
//        appends it under the direct `if swallowsFirstModeTap` guard, the
//        two mode buttons both `guard consumeModeTap()`, and
//        `testKeyboardIsScopedToTerminalSurface` launches with the literal
//        and asserts the `swallowedModeTap=true` witness; the harness file's
//        first effective line stays the `#if os(iOS) && DEBUG` gate.
//
//  All assertions are SLICE-scoped: the helper body is brace-matched, the
//  harness marker is scoped to `TerminalKeyboardUITestHarness`'s
//  `refreshDiagnostics` body (the file also carries the split harness, whose
//  `refreshDiagnostics` must NOT emit the marker), and the swallow literal is
//  counted per file plus scoped to its writer/reader function bodies.
//
//  FORMATTING HEURISTIC, NOT A PROOF. These pins parse Swift as text.
//  Honest defeat list: a computed-key re-expression (`String("isHittable")`,
//  reflection, KVC) or a `XCTWaiter` re-expression; a decoy token in a
//  string literal (comments are stripped, string contents are not); a
//  mechanism extracted into a helper the slice does not name (then the
//  anchor checks red, fail-closed); dead code (`if false { … }`) a source
//  pin cannot disprove; the runtime behavior itself — whether the coordinate
//  touch lands is E0/the shard-1 run's oracle, not this file's; the
//  diagnostics marker's 0.15 s tick bounds its freshness; a coherent
//  code+pin edit (inherent to update-on-purpose pins — the bound `3` and the
//  field tokens are update-on-purpose); the marker derivation is pinned as
//  the exact `showsTerminal ? "terminal" : "other"` spelling, so an
//  equivalent re-expression reds rather than silently diverging; the
//  first-wins marker parse over the whole label could alias a future
//  `selText=` value that spells the literal token (unreachable today — the
//  recovery's callers never select text); the split-harness zero-token check
//  is bounded by the next `struct`, so a marker added in an extension of the
//  split harness placed after it would escape; and a `func` spelling the
//  brace matcher cannot follow (e.g. braces inside the body's string
//  literals) reds as a missing or oversized slice rather than passing.
//
//  This is one more copy of the `repositoryRoot()` + `VVTERM_PINS_SOURCE_ROOT`
//  source-scan idiom (the #450 census lists 7; this worktree carries 33
//  `VVTermTests` files with the `VVTERM_PINS_SOURCE_ROOT` + `repositoryRoot()`
//  shape, 23 with `strippingComments` (the intersection with the
//  `VVTERM_PINS_SOURCE_ROOT` set) and 20 with the `VVTerm.xcodeproj`
//  walk), so the ordinal framing is dropped; #450 tracks the shared-scanner
//  extraction. The #444 note's "re-evaluate at the eighth" trigger is
//  discharged by an explicit decision to defer again: the #441 plan §4
//  specifies a self-contained pin suite, and a shared scanner would refactor
//  six landed pin suites inside a flake fix. Recorded as a residual on the PR.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment (a
//  plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct KeyboardModeSwitchTapRecoveryPinsTests {

    // MARK: - Frozen inputs

    private static let uiTestsPath = "VVTermUITests/TerminalKeyboardUITests.swift"
    private static let harnessPath = "VVTerm/App/iOS/TerminalKeyboardUITestHarness+iOS.swift"

    private static let helperName = "tapModeSwitchAndWaitForSurface"
    private static let markerToken = "harnessMode="
    private static let witnessToken = "swallowedModeTap="
    private static let coordinateTapToken =
        "coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()"
    private static let swallowToken = "--vvterm-ui-test-mode-buttons-swallow-first-tap"
    private static let swallowLiteral = "\"\(swallowToken)\""
    private static let attemptBoundAnchor = "for attempt in 1...3"

    /// P1: the helper's only tap is the landed #444 coordinate idiom.
    @Test
    func testP1TheHelperDispatchesOnlyTheCoordinateTapMechanism() throws {
        let body = try Self.helperBody()
        let taps = Self.count(of: ".tap()", in: body)
        #expect(
            taps == 1,
            "the mode-switch helper must dispatch exactly one `.tap()` — found \(taps); a bare element tap restores the refused `hitPoint:` mechanism this recovery exists to avoid (issue #441)"
        )
        let coordinateTaps = Self.count(of: Self.coordinateTapToken, in: body)
        #expect(
            coordinateTaps == 1,
            "the single tap must be the inline `\(Self.coordinateTapToken)` — found \(coordinateTaps) (issue #441)"
        )
        #expect(
            !body.contains("isHittable"),
            "the helper must not read `isHittable`: that getter records the `Computed hit point {-1, -1}` path on this host (issue #441)"
        )
        for banned in ["element.tap()", "button.tap()"] {
            #expect(
                !body.contains(banned),
                "the helper must not use a bare `\(banned)` — the element-tap path is the one that failed and then repeated verbatim (issue #441)"
            )
        }
    }

    /// P2: marker-keyed, ordered, bounded retry; boundary-safe marker parse.
    @Test
    func testP2TheHelperRetryIsMarkerKeyedOrderedAndBounded() throws {
        let body = try Self.helperBody()
        let bounds = Self.attemptBounds(in: body)
        #expect(
            bounds == ["3"],
            "the helper's attempt loop must be the literal `\(Self.attemptBoundAnchor)` — found \(bounds); raising the bound is a pin update (issue #441)"
        )
        let anchors = [
            Self.attemptBoundAnchor,
            "markerBefore = harnessMode(in: app)",
            Self.coordinateTapToken,
            "waitForHarnessModeChange(from: markerBefore",
            "surface.waitForExistence(timeout:",
            "XCTAssertTrue(",
        ]
        for anchor in anchors {
            #expect(
                body.contains(anchor),
                "the helper's retry must contain `\(anchor)` (issue #441)"
            )
        }
        #expect(
            Self.appearsInOrder(anchors, in: body),
            "the helper's retry anchors must appear in order \(anchors): marker capture before the coordinate tap, then the marker-change predicate, then the bounded surface wait and the terminal assertion (issue #441)"
        )
        #expect(
            Self.count(of: "waitForHarnessModeChange(from: markerBefore", in: body) == 1,
            "the retry must be keyed on exactly one marker-change predicate (issue #441)"
        )
        #expect(
            !body.contains("_ = surface.waitForExistence"),
            "the changed-marker branch must not discard the bounded surface wait (`_ = surface.waitForExistence`) and return — that returns green with the surface unverified (issue #441)"
        )
        #expect(
            body.contains("if surface.waitForExistence(timeout: timeout) { return } break"),
            "the changed-marker branch must keep the surface wait: `if surface.waitForExistence(timeout: timeout) { return }` when it appeared, else `break` into the terminal assertion (issue #441)"
        )
        let returns = Self.count(of: "return", in: body)
        #expect(
            returns == 1,
            "the helper body must contain exactly one `return` (the landed-switch early return) — found \(returns); the changed-marker fallback must not add a second success path (issue #441)"
        )
        let predicateBody = try Self.waitForHarnessModeChangeBody()
        #expect(
            Self.count(
                of: "guard previous != \"unknown\" else { return false }",
                in: predicateBody
            ) == 1,
            "the marker-change predicate must reject a captured `unknown` baseline (exactly one `guard previous != \"unknown\" else { return false }`) — otherwise a lost tap whose marker was unreadable reads as landed and skips the retry (issue #441)"
        )
        let readerBody = try Self.readerBody()
        #expect(
            Self.count(of: "hasPrefix(\"\(Self.markerToken)\")", in: readerBody) == 1,
            "the `harnessMode` reader must parse the `\(Self.markerToken)` token with exactly one boundary-safe `hasPrefix` — a renamed harness/helper token pair must red this pin (issue #441)"
        )
    }

    /// P3: one terminal assertion, carrying every recovery diagnostic field.
    @Test
    func testP3TheHelperTerminalAssertionCarriesTheRecoveryFields() throws {
        let body = try Self.helperBody()
        let assertions =
            Self.count(of: "XCTAssertTrue(", in: body) + Self.count(of: "XCTFail(", in: body)
        #expect(
            assertions == 1,
            "the helper must keep exactly one terminal assertion — found \(assertions); a second reds this pin (issue #441)"
        )
        for token in ["markerBefore=", "markerAfter=", "frame=", "exists="] {
            #expect(
                body.contains(token),
                "the terminal assertion message must carry the `\(token)` field token (issue #441)"
            )
        }
        #expect(
            !body.contains("isHittable"),
            "the terminal assertion message must not carry `isHittable` — the getter itself records the hit-point condition and would replace the diagnostic (issue #441)"
        )
    }

    /// P4: the marker in every keyboard-harness diagnostics branch, and only
    /// there.
    @Test
    func testP4TheHarnessMarkerIsEmittedInBothDiagnosticsBranches() throws {
        let source = try Self.normalizedSource(Self.harnessPath)
        let refreshBody = try Self.keyboardHarnessRefreshBody(in: source)
        let assignments = Self.count(of: "diagnostics =", in: refreshBody)
        #expect(
            assignments == 2,
            "the keyboard harness must emit diagnostics from exactly two branches — found \(assignments) `diagnostics =` assignments (issue #441)"
        )
        let markers = Self.count(of: Self.markerToken, in: refreshBody)
        #expect(
            markers == assignments,
            "every `diagnostics =` assignment in the keyboard harness must emit `\(Self.markerToken)` — found \(markers) markers for \(assignments) assignments; the `terminalView == nil` branch is the `other` state the recovery must detect (issue #441)"
        )
        let derivation = "showsTerminal ? \"terminal\" : \"other\""
        let derived = Self.count(of: derivation, in: refreshBody)
        #expect(
            derived == assignments,
            "every marker emission must be derived from `showsTerminal` (found \(derived) of `\(derivation)` for \(assignments) assignments) (issue #441)"
        )
        let witnessMarkers = Self.count(of: Self.witnessToken, in: refreshBody)
        #expect(
            witnessMarkers == assignments,
            "every `diagnostics =` assignment in the keyboard harness must emit `\(Self.witnessToken)` — found \(witnessMarkers) for \(assignments) assignments; the witness is what makes the swallow control self-proving (issue #441)"
        )
        let segments = refreshBody.components(separatedBy: "diagnostics =").dropFirst()
        for segment in segments {
            #expect(
                segment.contains(Self.markerToken),
                "the `diagnostics =` segment `\(segment.prefix(80))` must emit `\(Self.markerToken)` (issue #441)"
            )
        }
        let splitSlice = try Self.splitHarnessSlice(in: source)
        // Boundary: the split slice ends at the next `struct`, so a marker
        // added in an extension of the split harness placed after that struct
        // would escape these zero-token checks (issue #441).
        #expect(
            !splitSlice.contains(Self.markerToken),
            "the split harness must not emit `\(Self.markerToken)` — the marker is the keyboard harness' observable only (issue #441)"
        )
        #expect(
            !splitSlice.contains(Self.witnessToken),
            "the split harness must not emit `\(Self.witnessToken)` — the swallow witness is the keyboard harness' observable only (issue #441)"
        )
    }

    /// P5: the swallow positive control is wired once per file and the
    /// harness stays behind the iOS/DEBUG gate.
    @Test
    func testP5TheSwallowLaunchIsWiredOncePerFile() throws {
        let uiSource = try Self.normalizedSource(Self.uiTestsPath)
        #expect(
            Self.count(of: Self.swallowLiteral, in: uiSource) == 1,
            "the swallow launch literal must appear exactly once in the UI-test file (the `launchKeyboardHarness` writer) (issue #441)"
        )
        let launcherBody = Self.functionBody(named: "launchKeyboardHarness", in: uiSource)
        #expect(
            launcherBody?.contains(Self.swallowLiteral) == true,
            "the swallow launch literal must live in `launchKeyboardHarness` (issue #441)"
        )
        let launcherNeedle =
            "if swallowsFirstModeTap { app.launchArguments.append(\(Self.swallowLiteral)) }"
        #expect(
            launcherBody?.contains(launcherNeedle) == true,
            "the swallow literal must be appended under the direct `if swallowsFirstModeTap` guard — an inverted, negated or indirect condition silently disables the only deterministic retry coverage (issue #441)"
        )
        let testBody = Self.functionBody(
            named: "testKeyboardIsScopedToTerminalSurface",
            in: uiSource
        )
        #expect(
            testBody?.contains("launchKeyboardHarness(swallowsFirstModeTap: true)") == true,
            "`testKeyboardIsScopedToTerminalSurface` must launch with the swallow control — without it the retry + marker + coordinate-tap path has no deterministic CI coverage (issue #441)"
        )
        #expect(
            testBody?.contains("\(Self.witnessToken)true") == true,
            "`testKeyboardIsScopedToTerminalSurface` must assert the runtime witness `\(Self.witnessToken)true` — without it a launch-argument delivery failure silently degrades to the normal path with a green test (issue #441)"
        )

        let harnessSource = try Self.normalizedSource(Self.harnessPath)
        #expect(
            Self.count(of: Self.swallowLiteral, in: harnessSource) == 1,
            "the harness must read the swallow launch literal exactly once (issue #441)"
        )
        let keyboardSlice = try Self.keyboardHarnessSlice(in: harnessSource)
        #expect(
            keyboardSlice.contains(Self.swallowLiteral),
            "the swallow reader must live in `TerminalKeyboardUITestHarness` (issue #441)"
        )
        let consumeGuards = Self.count(of: "guard consumeModeTap() else { return }", in: keyboardSlice)
        #expect(
            consumeGuards == 2,
            "the two mode buttons (Terminal/Other) must both call `guard consumeModeTap() else { return }` — found \(consumeGuards); removing either disables the deterministic swallow coverage (issue #441)"
        )
        let firstLine = try Self.firstEffectiveLine(of: Self.harnessPath)
        #expect(
            firstLine == "#if os(iOS) && DEBUG",
            "the harness file's first effective line must stay the `#if os(iOS) && DEBUG` gate — found `\(firstLine)` (issue #441)"
        )
    }

    // MARK: - Source helpers

    private static func helperBody() throws -> String {
        let source = try normalizedSource(uiTestsPath)
        guard let body = functionBody(named: helperName, in: source) else {
            throw PinFailure(
                "could not extract the `\(helperName)` body from \(uiTestsPath) — the recovery helper is gone or respelled (issue #441)"
            )
        }
        return body
    }

    /// The body of the `harnessMode` reader that owns the boundary-safe
    /// `harnessMode=` parse (issue #441).
    private static func readerBody() throws -> String {
        let source = try normalizedSource(uiTestsPath)
        guard let body = functionBody(named: "harnessMode", in: source) else {
            throw PinFailure(
                "could not extract the `harnessMode` reader body from \(uiTestsPath) — re-derive this pin (issue #441)"
            )
        }
        return body
    }

    /// The body of the `waitForHarnessModeChange` predicate that owns the
    /// `unknown`-baseline guard (issue #441).
    private static func waitForHarnessModeChangeBody() throws -> String {
        let source = try normalizedSource(uiTestsPath)
        guard let body = functionBody(named: "waitForHarnessModeChange", in: source) else {
            throw PinFailure(
                "could not extract the `waitForHarnessModeChange` predicate body from \(uiTestsPath) — re-derive this pin (issue #441)"
            )
        }
        return body
    }

    private static func keyboardHarnessRefreshBody(in source: String) throws -> String {
        let harness = try keyboardHarnessSlice(in: source)
        guard let body = functionBody(named: "refreshDiagnostics", in: harness) else {
            throw PinFailure(
                "could not extract `refreshDiagnostics` from TerminalKeyboardUITestHarness — re-derive this pin (issue #441)"
            )
        }
        return body
    }

    private static func keyboardHarnessSlice(in source: String) throws -> String {
        guard let start = source.range(of: "struct TerminalKeyboardUITestHarness: View {"),
              let end = source.range(
                of: "struct TerminalSplitKeyboardUITestHarness: View {",
                range: start.upperBound..<source.endIndex
              ) else {
            throw PinFailure(
                "could not slice `TerminalKeyboardUITestHarness` out of \(harnessPath) — the struct order/names changed (issue #441)"
            )
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    private static func splitHarnessSlice(in source: String) throws -> String {
        guard let start = source.range(of: "struct TerminalSplitKeyboardUITestHarness: View {"),
              let end = source.range(
                of: "struct TerminalKeyboardHarnessRepresentable:",
                range: start.upperBound..<source.endIndex
              ) else {
            throw PinFailure(
                "could not slice `TerminalSplitKeyboardUITestHarness` out of \(harnessPath) — the struct order/names changed (issue #441)"
            )
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// The brace-matched body of the named function on a comment-stripped,
    /// whitespace-normalized source. Returns nil when the function is missing
    /// or the braces do not balance (which reds the caller's pin).
    private static func functionBody(named name: String, in source: String) -> String? {
        guard let signature = source.range(of: "func \(name)("),
              let openBrace = source[signature.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBrace...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func appearsInOrder(_ needles: [String], in text: String) -> Bool {
        var searchStart = text.startIndex
        for needle in needles {
            guard let range = text.range(of: needle, range: searchStart..<text.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    private static func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func attemptBounds(in text: String) -> [String] {
        let pattern = #"for attempt in 1\.\.\.([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func firstEffectiveLine(of relativePath: String) throws -> String {
        let raw = try source(relativePath)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        throw PinFailure("\(relativePath) has no effective first line (issue #441)")
    }

    private static func normalizedSource(_ relativePath: String) throws -> String {
        let stripped = Self.strippingComments(try Self.source(relativePath))
        return stripped.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

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
        // source with the UI test / harness files mutated. The measured-working
        // form is `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` exported
        // into xcodebuild's own environment (the `TEST_RUNNER_` prefix is
        // consumed by the test runner and forwarded without it).
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
    /// pin file is self-contained and reverts independently (#450 tracks the
    /// shared-scanner extraction).
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

}
