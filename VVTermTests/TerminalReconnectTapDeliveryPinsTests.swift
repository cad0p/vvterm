// SPDX-License-Identifier: MIT
//
//  TerminalReconnectTapDeliveryPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #220: `VVTermUITests/TerminalReconnectUITests.swift`
//  no longer passes or fails on the wall-clock duration of a tap. The removed
//  `tapPromptly` asserted `XCTAssertLessThan(Date().timeIntervalSince(...), 10, …)`
//  and reddened on a tap that had delivered while a loaded runner stalled it
//  (18.382 s in the CI instance, 47.159 s on #257) with `sentCount`/
//  `transportSent` advanced and the app healthy. It is replaced by
//  `tapAndAwaitInput`, which taps and bounded-waits
//  (`inputDeliveryBudget = 30 s`) for the delivered-input counter `sentCount`
//  to advance, returning a Bool that every call site consumes (asserted at the
//  three direct sites, fed into the existing retry at the two session sites).
//
//    A1  no wall-clock threshold survives: zero `XCTAssertLessThan(` in the
//        file, and exactly one `timeIntervalSince` read — the helper's
//        `elapsed=` triage print (its context carries `elapsed=`). Plan §4.1
//        A1 said "zero `timeIntervalSince` occurrences", but §3.1's helper
//        (lens-1 F3) requires the elapsed diagnostic, so this pin locks the
//        threshold shape, not the bare token. A re-added `tapPromptly` reds
//        both halves (the count becomes two and `XCTAssertLessThan(` returns).
//    A2  zero `tapPromptly` occurrences (a revert to the old helper name is
//        visible).
//    A3  exactly one `inputDeliveryBudget` declaration with literal 30, and
//        the helper's normalized signature keeps the default binding
//        `timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget`
//        (`Self.` is a compile error in a default argument — lens-1 F1; the
//        pin is needed because a bare constant is not enough: the default could
//        silently become a literal).
//    A4  exactly one `private func tapAndAwaitInput(` and the delivery check
//        `now > before`.
//    A5  call-site shapes: exactly three `XCTAssertTrue(tapAndAwaitInput(`
//        and exactly two `delivered = tapAndAwaitInput(` — the declaration is
//        excluded because it is spelled `private func tapAndAwaitInput(`.
//    A6  the four bare taps in `tapCommandArguments` keep their delivery
//        backing: exactly two `containing: enterTarget` waits (the Return
//        key/button path) and the `terminal.typeText("\n")` IME fallback.
//
//  Scans run over the comment-stripped, whitespace-normalized source: a
//  comment-embedded decoy is not code, and a multi-line call site normalizes
//  to one logical line. FORMATTING HEURISTIC, NOT A PROOF: this file parses
//  Swift as text.
//
//  Honest defeat list:
//    - a differently-spelled wall-clock read (`CFAbsoluteTimeGetCurrent`,
//      `ProcessInfo.systemUptime`) escapes A1's token count — but the
//      `XCTAssertLessThan(` half still catches it as an assertion;
//    - a tap-latency assertion in another file is out of scope;
//    - A4 proves the text, not runtime liveness (that is CF-R2);
//    - a coherent edit paired with a pin update is inherent to an
//      update-on-purpose pin;
//    - the retry sites' control flow is text-pinned by A5, not runtime-proven;
//      CF-R4 (the `return false` helper mutation on the session test) is what
//      demonstrates the retry body executes and the pre-existing
//      `XCTAssertTrue(delivered, …)` reds — its result is recorded in the
//      evidence bundle at
//      `assets/vvterm-issue220-evidence/README.md`.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment
//  (a plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct TerminalReconnectTapDeliveryPinsTests {

    private static let uiTestsPath = "VVTermUITests/TerminalReconnectUITests.swift"

    /// The normalized helper signature. The `timeout:` default must bind the
    /// named budget, not a literal and not `Self.` (a default-argument
    /// compile error).
    private static let helperSignature =
        "private func tapAndAwaitInput( _ key: XCUIElement, diagnostics: XCUIElement, app: XCUIApplication, timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget ) -> Bool"

    /// A1: the tap-duration threshold is gone. The one permitted
    /// `timeIntervalSince` is the helper's `elapsed=` triage print.
    @Test
    func testA1NoWallClockTapThresholdSurvives() throws {
        let source = try Self.normalizedSource()
        #expect(
            !source.contains("XCTAssertLessThan("),
            "no `XCTAssertLessThan(` may survive in TerminalReconnectUITests.swift: a wall-clock threshold on a tap is what #220 removed — re-derive this pin (issue #220)"
        )
        let occurrences = source.components(separatedBy: "timeIntervalSince").count - 1
        #expect(
            occurrences == 1,
            "exactly one `timeIntervalSince` read may survive — the helper's `elapsed=` triage print; a re-added tap-duration assertion makes it two — found \(occurrences) (issue #220)"
        )
        #expect(
            Self.firstOccurrenceContext(of: "timeIntervalSince", in: source)?.contains("elapsed=") == true,
            "the surviving `timeIntervalSince` must be the helper's `elapsed=` triage print, not a pass/fail threshold (issue #220)"
        )
    }

    /// A2: the old helper name is gone.
    @Test
    func testA2TapPromptlyIsGone() throws {
        let source = try Self.normalizedSource()
        let occurrences = source.components(separatedBy: "tapPromptly").count - 1
        #expect(
            occurrences == 0,
            "`tapPromptly` must not survive in TerminalReconnectUITests.swift — found \(occurrences) (issue #220)"
        )
    }

    /// A3: the budget constant and the helper's default binding are pinned.
    @Test
    func testA3TheBudgetLiteralAndDefaultBindingArePinned() throws {
        let source = try Self.normalizedSource()
        let literals = Self.budgetLiterals(in: source)
        #expect(
            literals == ["30"],
            "`inputDeliveryBudget` must be declared exactly once with the literal 30 (update on purpose: shrinking the budget shrinks the delivered-tap allowance #220 widened) — found \(literals) (issue #220)"
        )
        #expect(
            source.contains(Self.helperSignature),
            "the helper's normalized signature must keep its `timeout: TimeInterval = TerminalReconnectUITests.inputDeliveryBudget` default — expected `\(Self.helperSignature)` (issue #220)"
        )
    }

    /// A4: one helper, with the counter-advance check.
    @Test
    func testA4TheHelperAndItsDeliveryCheckExist() throws {
        let source = try Self.normalizedSource()
        let helperOccurrences = source.components(separatedBy: "private func tapAndAwaitInput(").count - 1
        #expect(
            helperOccurrences == 1,
            "exactly one `private func tapAndAwaitInput(` must exist — found \(helperOccurrences) (issue #220)"
        )
        #expect(
            source.contains("now > before"),
            "the helper must keep the delivered-input check `now > before` (a `return true` would make every tap pass) (issue #220)"
        )
    }

    /// A5: the call-site shapes.
    @Test
    func testA5CallSiteShapesArePinned() throws {
        let source = try Self.normalizedSource()
        let asserted = source.components(separatedBy: "XCTAssertTrue(tapAndAwaitInput(").count - 1
        #expect(
            asserted == 3,
            "exactly three direct sites must assert the returned delivery Bool — found \(asserted) (issue #220)"
        )
        let retried = source.components(separatedBy: "delivered = tapAndAwaitInput(").count - 1
        #expect(
            retried == 2,
            "exactly two retry sites must feed the returned Bool into `delivered` — found \(retried) (issue #220)"
        )
    }

    /// A6: the four bare taps keep their downstream delivery waits.
    @Test
    func testA6BareTapsKeepTheirDeliveryBacking() throws {
        let source = try Self.normalizedSource()
        let enterWaits = source.components(separatedBy: "containing: enterTarget").count - 1
        #expect(
            enterWaits == 2,
            "the Return key/button path must keep its two `containing: enterTarget` waits — found \(enterWaits) (issue #220)"
        )
        #expect(
            source.contains("terminal.typeText(\"\\n\")"),
            "the IME newline fallback `terminal.typeText(\"\\n\")` must remain after the Return key/button taps (issue #220)"
        )
    }

    // MARK: - Source helpers

    /// The window around the first occurrence of `token` (for the elapsed-print
    /// context assertion).
    private static func firstOccurrenceContext(of token: String, in source: String) -> String? {
        guard let range = source.range(of: token) else { return nil }
        let start = source.index(range.lowerBound, offsetBy: -200, limitedBy: source.startIndex)
            ?? source.startIndex
        return String(source[start..<range.upperBound])
    }

    /// Every `inputDeliveryBudget` declaration literal, in file order.
    private static func budgetLiterals(in source: String) -> [String] {
        let pattern = #"static let inputDeliveryBudget: TimeInterval = ([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    private static func normalizedSource() throws -> String {
        let stripped = Self.strippingComments(try Self.source(Self.uiTestsPath))
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
        // source with the UI test file mutated. The measured-working form is
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
