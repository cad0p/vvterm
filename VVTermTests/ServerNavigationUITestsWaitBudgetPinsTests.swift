// SPDX-License-Identifier: MIT
//
//  ServerNavigationUITestsWaitBudgetPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #400: the four diagnostics-label waits in
//  `VVTermUITests/ServerNavigationUITests.swift` that used to rely on the
//  shared helper's 10 s default (`shell=true` ×1, `setup=ready` ×2,
//  `setup=ready state=connected` ×1) now pass `Self.diagnosticsWaitBudget`
//  (30 s), and the helper's `timeout:` default is removed so a new
//  default-timeout call site cannot compile.
//
//    A1  the diagnostics helper's `timeout:` parameter has no default, and
//        the file contains no `timeout: TimeInterval =` (a missed default
//        would let the removed 10 s return);
//    A2  exactly four `timeout: Self.diagnosticsWaitBudget` call sites, with
//        the exact token pairings: `shell=true` ×1, `setup=ready` ×2,
//        `setup=ready state=connected` ×1;
//    A3  the `diagnosticsWaitBudget` declaration exists exactly once and its
//        literal is 30 (update-on-purpose: the unsafe direction is a silent
//        30→10 edit re-opening #400's starvation red; the in-tree
//        counter-precedent for pinning a test-internal numeric budget is
//        `VVTermTests/SSH/SSHUploadIntegrationConnectBudgetPinsTests.swift`);
//    A4  every `containing:` call site in the file (12) carries a `timeout:`
//        argument, so a new default-timeout site of any budget is visible.
//
//  Scans run over the comment-stripped, whitespace-normalized source: a
//  comment-embedded decoy is not code, and a multi-line call site
//  normalizes to one logical line. FORMATTING HEURISTIC, NOT A PROOF: this
//  file parses Swift as text.
//
//  Honest defeat list (plan §3.5, corrected by impl lens 2 finding 1):
//    - a NEW call site is caught by A4's 12-count and scan-consistency
//      checks (both measured red: a literal 13th site and a scan-hidden
//      one); the residual that DOES escape is a short explicit literal at
//      the other eight diagnostics sites (`timeout: 45` → 10 keeps all
//      four pins green) and any edit paired with a deliberate pin-file
//      update (inherent to an update-on-purpose pin);
//    - a re-added default in another file's helper copy is out of scope.
//      Examples, not a census: the TerminalZenMode / ZmxScrollbackReload /
//      TerminalReconnect copies already require `timeout:`;
//      `TerminalScreenAwakeUITests` (5/8/8), `TerminalKeyboardUITests`,
//      `TerminalLinkTapUITests` (8), `NoticePresentationUITests` (30),
//      `StatsCardsLayoutUITests` (40/5) and `UITestLaunchSupport` (10) keep
//      their own defaults — none is this class's hazard.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scan at a
//  mutated tree copy. The variable reaches the test process only as
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT` in xcodebuild's own environment
//  (a plain env var is inert on the simulator destination). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct ServerNavigationUITestsWaitBudgetPinsTests {

    private static let uiTestsPath = "VVTermUITests/ServerNavigationUITests.swift"

    /// The normalized diagnostics-helper signature. The `timeout:` parameter
    /// carries no `= …` default, so the literal is part of the pin.
    private static let helperSignature =
        "func wait( for element: XCUIElement, containing expected: String, timeout: TimeInterval, app: XCUIApplication )"

    /// The four token pairings the pin locks (plan §3.5 A2).
    private static let expectedBudgetTokens = [
        "setup=ready",
        "setup=ready",
        "setup=ready state=connected",
        "shell=true",
    ]

    /// A1: the helper's `timeout:` has no default, and no default of this
    /// shape survives anywhere in the file. Lens 3 F5: the helper-shape
    /// assertion is separate from the file-wide scan because
    /// `waitForAppState` also takes a `timeout: TimeInterval`.
    @Test
    func testA1TheDiagnosticsHelperTimeoutHasNoDefault() throws {
        let source = try Self.normalizedSource()
        #expect(
            source.contains(Self.helperSignature),
            "the diagnostics helper must keep its normalized signature `\(Self.helperSignature)` with a default-less `timeout:` — re-derive this pin (issue #400)"
        )
        #expect(
            !source.contains("timeout: TimeInterval ="),
            "no `timeout: TimeInterval = …` default may survive in ServerNavigationUITests.swift: a default re-opens the 10 s starvation red #400 removed — re-derive this pin (issue #400)"
        )
    }

    /// A2: exactly four diagnostics waits take the named budget, with the
    /// exact token pairing.
    @Test
    func testA2ExactlyFourSitesTakeTheNamedBudgetWithTheExactTokens() throws {
        let source = try Self.normalizedSource()
        let occurrences = source.components(separatedBy: "timeout: Self.diagnosticsWaitBudget").count - 1
        #expect(
            occurrences == 4,
            "exactly four diagnostics waits must pass `timeout: Self.diagnosticsWaitBudget` (the #400 sites) — found \(occurrences); a new/removed site or a literal budget is a pin update (issue #400)"
        )

        let budgetTokens = Self.helperCallSites(in: source)
            .filter { $0.contains("timeout: Self.diagnosticsWaitBudget") }
            .compactMap(Self.containingToken(in:))
        #expect(
            budgetTokens.sorted() == Self.expectedBudgetTokens,
            "the four `Self.diagnosticsWaitBudget` sites must pair with `shell=true` ×1, `setup=ready` ×2 and `setup=ready state=connected` ×1 — found \(budgetTokens.sorted()) (issue #400)"
        )
    }

    /// A3: the constant is declared exactly once and its literal is pinned.
    @Test
    func testA3TheBudgetLiteralIsPinned() throws {
        let source = try Self.normalizedSource()
        let literals = Self.budgetLiterals(in: source)
        #expect(
            literals == ["30"],
            "`diagnosticsWaitBudget` must be declared exactly once with the literal 30 (update on purpose: a 30→10 edit re-opens #400) — found \(literals) (issue #400)"
        )
    }

    /// A4: every `containing:` call site carries a `timeout:` argument.
    /// The `missing.isEmpty` check is belt-and-braces: the helper default is
    /// gone, so no compilable tree reaches this test with a missing timeout.
    /// The load-bearing checks are the 12-count and the
    /// `callSites == containingSites` scan-consistency (both measured red).
    @Test
    func testA4EveryDiagnosticsCallSitePassesATimeout() throws {
        let source = try Self.normalizedSource()
        let containingSites = source.components(separatedBy: "containing: ").count - 1
        let callSites = Self.helperCallSites(in: source)
        #expect(
            callSites.count == containingSites,
            "the call-site scan must cover every `containing:` site (found \(callSites.count) call sites vs \(containingSites) `containing:` tokens) — re-derive this pin (issue #400)"
        )
        #expect(
            callSites.count == 12,
            "the diagnostics helper must keep 12 call sites — found \(callSites.count): a new site is a pin update (issue #400)"
        )
        let missing = callSites.filter { !$0.contains("timeout:") }
        #expect(
            missing.isEmpty,
            "every diagnostics call site must pass an explicit `timeout:` (the helper default is gone) — sites without one: \(missing) (issue #400)"
        )
    }

    // MARK: - Source helpers

    /// The diagnostics helper's call sites, from the `wait(for: diagnostics,`
    /// marker to the closing `, app: app)`. Works on the whitespace-normalized
    /// source, so a multi-line call site is one logical line.
    private static func helperCallSites(in source: String) -> [String] {
        var sites: [String] = []
        var searchStart = source.startIndex
        while let start = source.range(of: "wait(for: diagnostics,", range: searchStart..<source.endIndex) {
            guard let end = source.range(of: ", app: app)", range: start.upperBound..<source.endIndex) else {
                break
            }
            sites.append(String(source[start.lowerBound..<end.upperBound]))
            searchStart = end.upperBound
        }
        return sites
    }

    /// The `containing: "…"` token of a call site.
    private static func containingToken(in site: String) -> String? {
        guard let start = site.range(of: "containing: \""),
              let end = site[start.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(site[start.upperBound..<end])
    }

    /// Every `diagnosticsWaitBudget` declaration literal, in file order.
    private static func budgetLiterals(in source: String) -> [String] {
        let pattern = #"static let diagnosticsWaitBudget: TimeInterval = ([0-9.]+)"#
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
