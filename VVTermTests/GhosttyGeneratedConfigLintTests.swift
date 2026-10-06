// SPDX-License-Identifier: MIT
//
//  GhosttyGeneratedConfigLintTests.swift
//  VVTermTests
//
//  Builder-boundary lint for issue #381: `Ghostty.ConfigBuilder.configContent`
//  must emit each variant's key set from an explicit inventory, must not emit
//  a non-repeatable key twice, and must not emit a core-accepted silent alias.
//  The measured alias is `scrollback-limit`: the core maps it to
//  `scrollback-limit-bytes` (bytes, not lines) with no diagnostic, so a
//  builder swap back to it would pass the diagnostics check while silently
//  turning "10 000 lines" into "10 000 bytes" (issue #247's second defect).
//
//  Origin: #247 measured that `scripts/ci/check-ghostty-config.sh` is a
//  *diagnostics* oracle — it catches every key the core rejects, but the core
//  silently accepts compatibility renames and duplicate keys (last wins).
//  This suite closes that class at the builder boundary, where a deliberate
//  key-set change is visible and reviewable in the same PR.
//
//  Oracle boundary, stated honestly: this lint runs over the builder's output
//  only, so it cannot prove the vendored core still assigns each emitted key
//  its current meaning. The C probe owns core acceptance; a core-side rename
//  or meaning change of a non-C-readable key (`Limit`-typed keys have no
//  `cval`) has no exposed oracle and is tracked in issue #382.
//
//  Companion coverage (kept, not replaced):
//  - `GhosttyConfigBuilderTests.configContentKeepsNonFontLinesStable` pins the
//    *values* (`scrollback-limit-lines = 10000`, no `scrollback-limit = 10000`);
//    this suite makes the inventory structural and value-independent.
//  - `GhosttyGeneratedConfigFixturePinsTests` pins the checked-in fixtures
//    byte-exact to the builder output; the required `build` job then loads
//    those fixtures through the vendored core.
//
//  Maintenance: a legitimate builder key-set change updates `acceptedKeys`
//  and `excludedKeysPerVariant` in the same PR (every A1/A4 failure says so).
//  The `repeatableKeys` rationale is recorded at its declaration. The parser
//  is fail-closed: a non-comment line that is not a well-formed `key = value`
//  directive fails loudly instead of silently shrinking the observed key set.
//

import Foundation
import Testing

@testable import VVTerm

struct GhosttyGeneratedConfigLintTests {

    // MARK: - Recorded inventory (the maintenance surface)

    /// Every key `Ghostty.ConfigBuilder.configContent` is allowed to emit,
    /// mechanically extracted from the builder template (14 literal keys + 3
    /// dynamic keys). `scrollback-limit-bytes` is deliberately NOT here: it is
    /// a real core key with byte semantics, while the app's semantic is lines
    /// (`scrollback-limit-lines`); `deniedKeys` carries the units message.
    static let acceptedKeys: Set<String> = [
        "font-family",
        "font-size",
        "window-inherit-font-size",
        "window-padding-balance",
        "window-padding-x",
        "window-padding-y",
        "window-padding-color",
        "shell-integration",
        "shell-integration-features",
        "cursor-style",
        "cursor-style-blink",
        "theme",
        "scrollback-limit-lines",
        "mouse-scroll-multiplier",
        "keybind",
        "clipboard-read",
        "macos-option-as-alt",
    ]

    /// List-valued keys where repetition is the intended semantic (verified
    /// against vendored core e77b2309: `font-family: RepeatableString`
    /// Config.zig:173 / RepeatableString :6079 / parseCLI :6090-6107;
    /// `keybind: Keybinds` :1937). All other emitted keys are
    /// scalars/optionals/enums without list semantics.
    static let repeatableKeys: Set<String> = ["font-family", "keybind"]

    /// Keys the builder must never emit: silent aliases the core accepts with
    /// different semantics, plus a real core key the app deliberately does not
    /// use. Grows at a bump; `acceptedKeys` deliberately omits both so the
    /// inventory itself cannot bless them.
    static let deniedKeys: [String: String] = [
        "scrollback-limit": "the core maps it to `scrollback-limit-bytes` (bytes, not lines); emit `scrollback-limit-lines`",
        "scrollback-limit-bytes": "a real core key, but the app's semantic is lines; emit `scrollback-limit-lines`",
    ]

    /// Per-variant keys that must NOT be present (derived from the #381 §1
    /// presence space). The three conditional keys are `font-family` (all
    /// families blank), `theme` (empty) and `macos-option-as-alt`
    /// (`emitsPlatformInputConfig == false`, i.e. every non-macOS variant).
    static let excludedKeysPerVariant: [Variant: Set<String>] = [
        .iOS: ["macos-option-as-alt"],
        .macOS: [],
        .emptyTheme: ["theme", "macos-option-as-alt"],
        .emptyFont: ["font-family", "macos-option-as-alt"],
    ]

    // MARK: - Variant matrix

    enum Variant: String, CaseIterable {
        case iOS
        case macOS
        case emptyTheme
        case emptyFont

        var displayName: String {
            switch self {
            case .iOS: "iOS canonical"
            case .macOS: "macOS canonical"
            case .emptyTheme: "empty theme"
            case .emptyFont: "empty font"
            }
        }
    }

    struct VariantCase {
        let variant: Variant
        let content: String
        let expectedFontFamilyLines: Int
    }

    /// Canonical fixture inputs (the same tuple the byte pins use).
    static let canonicalPrimaryFontFamily = "Menlo"
    static let canonicalFontSize = 13.0
    static let canonicalShellName = "zsh"
    static let canonicalTheme = "Aizen Light"

    static func content(
        primaryFontFamily: String,
        theme: String,
        fallbackFontFamilies: [String],
        emitsPlatformInputConfig: Bool
    ) -> String {
        Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: primaryFontFamily,
            fontSize: canonicalFontSize,
            shellName: canonicalShellName,
            theme: theme,
            optionAsAltMode: .left,
            fallbackFontFamilies: fallbackFontFamilies,
            emitsPlatformInputConfig: emitsPlatformInputConfig
        )
    }

    /// The four variants cover the presence space of the three conditional
    /// keys. The macOS variant is built on any destination by passing the
    /// production inputs explicitly (the same technique as the byte pins).
    static let variants: [VariantCase] = [
        VariantCase(
            variant: .iOS,
            content: content(
                primaryFontFamily: canonicalPrimaryFontFamily,
                theme: canonicalTheme,
                fallbackFontFamilies: [],
                emitsPlatformInputConfig: false
            ),
            expectedFontFamilyLines: 1
        ),
        VariantCase(
            variant: .macOS,
            content: content(
                primaryFontFamily: canonicalPrimaryFontFamily,
                theme: canonicalTheme,
                fallbackFontFamilies: TerminalDefaults.macOSFallbackFontFamilies,
                emitsPlatformInputConfig: true
            ),
            expectedFontFamilyLines: 1 + TerminalDefaults.macOSFallbackFontFamilies.count
        ),
        VariantCase(
            variant: .emptyTheme,
            content: content(
                primaryFontFamily: canonicalPrimaryFontFamily,
                theme: "",
                fallbackFontFamilies: [],
                emitsPlatformInputConfig: false
            ),
            expectedFontFamilyLines: 1
        ),
        VariantCase(
            variant: .emptyFont,
            content: content(
                primaryFontFamily: "",
                theme: canonicalTheme,
                fallbackFontFamilies: [],
                emitsPlatformInputConfig: false
            ),
            expectedFontFamilyLines: 0
        ),
    ]

    static func expectedKeys(for variant: Variant) -> Set<String> {
        acceptedKeys.subtracting(excludedKeysPerVariant[variant] ?? [])
    }

    // MARK: - Parser (fail-closed)

    struct ParsedDirective: Equatable {
        let lineNumber: Int
        let key: String
        let value: String
    }

    enum ParseFailure: Error, CustomStringConvertible, Equatable {
        case missingSeparator(lineNumber: Int, rawLine: String)
        case invalidKey(lineNumber: Int, rawLine: String, key: String)
        case carriageReturn(lineNumber: Int, rawLine: String)

        var description: String {
            switch self {
            case .missingSeparator(let lineNumber, let rawLine):
                "line \(lineNumber) has no ' = ' separator: `\(rawLine)`"
            case .invalidKey(let lineNumber, let rawLine, let key):
                "line \(lineNumber) key `\(key)` does not match ^[a-z0-9-]+$: `\(rawLine)`"
            case .carriageReturn(let lineNumber, let rawLine):
                "line \(lineNumber) contains a carriage return (the builder emits LF; a CRLF line is one grapheme cluster in Swift, so it must be rejected by scalars, never parsed with the CR stuck to the value): `\(rawLine)`"
            }
        }
    }

    /// Parses the builder output into directives. Fail-closed: after
    /// `.whitespaces` trimming, any line containing a CR is rejected before
    /// blanks and `#`-comments are skipped (so a CRLF line can never be
    /// silently accepted), and every remaining line must be exactly
    /// `key = value` with the key full-matching `^[a-z0-9-]+$`.
    static func parsedDirectives(in content: String) throws -> [ParsedDirective] {
        var directives: [ParsedDirective] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.unicodeScalars.contains("\r") {
                throw ParseFailure.carriageReturn(lineNumber: lineNumber, rawLine: line)
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.range(of: " = ") else {
                throw ParseFailure.missingSeparator(lineNumber: lineNumber, rawLine: line)
            }
            let key = String(line[line.startIndex..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            guard key.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
                throw ParseFailure.invalidKey(lineNumber: lineNumber, rawLine: line, key: key)
            }
            directives.append(ParsedDirective(lineNumber: lineNumber, key: key, value: value))
        }
        return directives
    }

    private static func parseFailure(in content: String) -> ParseFailure? {
        do {
            _ = try parsedDirectives(in: content)
            return nil
        } catch let failure as ParseFailure {
            return failure
        } catch {
            Issue.record("unexpected parser error: \(error)")
            return nil
        }
    }

    // MARK: - Parser tests

    @Test
    func parserReadsDirectivesAndSkipsBlanksAndComments() throws {
        let directives = try Self.parsedDirectives(in: "# a comment\nfont-size = 13\n\n  cursor-style = block  \n")
        // `#require`, not `#expect`: the subscripts below must not trap on a
        // count regression (Swift Testing's `#expect` records and continues).
        try #require(directives.count == 2)
        #expect(directives[0] == Self.ParsedDirective(lineNumber: 2, key: "font-size", value: "13"))
        #expect(directives[1] == Self.ParsedDirective(lineNumber: 4, key: "cursor-style", value: "block"))
    }

    /// The `theme` value can contain ` = ` (the existing
    /// `themeValueWithPairSeparatorsIsStillEmittedAsOneQuotedValue` proves
    /// `,`; a name with `=` is the parser case), so the split must be on the
    /// first separator and the rest must stay one value.
    @Test
    func parserSplitsOnTheFirstSeparatorSoValuesMayContainEquals() throws {
        let directives = try Self.parsedDirectives(in: "theme = \"A = B\"\n")
        try #require(directives.count == 1)
        #expect(directives[0].key == "theme")
        #expect(directives[0].value == "\"A = B\"")

        let multi = try Self.parsedDirectives(in: "theme = \"A = B = C\"\n")
        try #require(!multi.isEmpty)
        #expect(multi[0].value == "\"A = B = C\"")
    }

    @Test
    func parserFailsLoudlyWithoutASeparator() {
        let failure = Self.parseFailure(in: "font-size 13\n")
        #expect(
            failure == .missingSeparator(lineNumber: 1, rawLine: "font-size 13"),
            "a non-comment line without ' = ' must fail loudly with .missingSeparator, not be skipped or misclassified"
        )
        #expect(failure?.description.contains("line 1") == true)
        #expect(failure?.description.contains("font-size 13") == true)
    }

    /// Anchoring: an unanchored `[a-z0-9-]+` match would accept `font size`
    /// on the `font` substring, silently mis-reading the key.
    @Test
    func parserFailsLoudlyOnANonMatchingKey() {
        let failure = Self.parseFailure(in: "font size = 13\n")
        #expect(
            failure == .invalidKey(lineNumber: 1, rawLine: "font size = 13", key: "font size"),
            "a key that does not full-match ^[a-z0-9-]+$ must fail loudly with .invalidKey, not be skipped or reported as a missing separator"
        )
        #expect(failure?.description.contains("font size = 13") == true)
    }

    @Test
    func parserRejectsCarriageReturnsInsteadOfTrimmingThem() {
        let failure = Self.parseFailure(in: "font-size = 13\r\n")
        #expect(failure != nil, "a CRLF config must fail loudly: `.whitespaces` trimming alone would leave the CR in the value")
        #expect(failure?.description.contains("carriage return") == true)
    }

    // MARK: - Assertions A0-A7

    /// A0 — parser shape guard. Every line the builder emits is a well-formed
    /// `key = value` directive; a silent parser drop would make the other
    /// assertions vacuous.
    @Test
    func parsedShapeGuard() {
        for variant in Self.variants {
            do {
                let directives = try Self.parsedDirectives(in: variant.content)
                #expect(
                    !directives.isEmpty,
                    "A0 — \(variant.variant.displayName): the parser found zero directives; an empty parse would make every other assertion vacuous"
                )
            } catch let failure as Self.ParseFailure {
                Issue.record("A0 — \(variant.variant.displayName): \(failure.description)")
            } catch {
                Issue.record("A0 — \(variant.variant.displayName): unexpected parse error \(error)")
            }
        }
    }

    /// A1 — subset. A new/renamed key must not pass through CI silently.
    @Test
    func emittedKeysAreInsideTheAcceptedInventory() throws {
        for variant in Self.variants {
            let directives = try Self.parsedDirectives(in: variant.content)
            for directive in directives {
                #expect(
                    Self.acceptedKeys.contains(directive.key),
                    "A1 — \(variant.variant.displayName): line \(directive.lineNumber) emits '\(directive.key)', which is not in acceptedKeys. If deliberate, update acceptedKeys in this suite and the check docs in the same PR; if this is a core rename, see issue #382"
                )
            }
        }
    }

    /// A2 — no silent alias. The denylist names the measured core-accepted
    /// aliases; unknown aliases are caught by A1, not here.
    @Test
    func emittedKeysAreNotKnownSilentAliases() throws {
        for variant in Self.variants {
            let directives = try Self.parsedDirectives(in: variant.content)
            for directive in directives {
                if let rationale = Self.deniedKeys[directive.key] {
                    Issue.record(
                        "A2 — \(variant.variant.displayName): line \(directive.lineNumber) emits the denied alias '\(directive.key)' — \(rationale). See issue #382 for the core-side class"
                    )
                }
            }
        }
    }

    /// A3 — duplicates. The core accepts duplicates last-wins with no
    /// diagnostic, so a non-repeatable key emitted twice is a silent
    /// meaning change.
    @Test
    func nonRepeatableKeysAppearAtMostOncePerVariant() throws {
        for variant in Self.variants {
            let directives = try Self.parsedDirectives(in: variant.content)
            let byKey = Dictionary(grouping: directives, by: \.key)
            for key in byKey.keys.sorted() {
                let occurrences = byKey[key] ?? []
                if occurrences.count > 1 {
                    let lines = occurrences.map(\.lineNumber).sorted().map(String.init).joined(separator: ", ")
                    #expect(
                        Self.repeatableKeys.contains(key),
                        "A3 — \(variant.variant.displayName): non-repeatable key '\(key)' appears \(occurrences.count) times (lines \(lines)); only repeatableKeys may repeat: \(Self.repeatableKeys.sorted())"
                    )
                }
            }
        }
    }

    /// A4 — exact per-variant key set. This is the executable form of the #381
    /// §1 presence table: a one-key drop, a hardcoded `font-family`, or any
    /// conditional-key change reds here.
    @Test
    func eachVariantEmitsExactlyItsExpectedKeySet() throws {
        for variant in Self.variants {
            let directives = try Self.parsedDirectives(in: variant.content)
            let emitted = Set(directives.map(\.key))
            let expected = Self.expectedKeys(for: variant.variant)
            let missing = expected.subtracting(emitted).sorted()
            let extra = emitted.subtracting(expected).sorted()
            #expect(
                missing.isEmpty && extra.isEmpty,
                "A4 — \(variant.variant.displayName): the emitted key set must equal acceptedKeys − excludedKeysPerVariant; missing \(missing), unexpected \(extra). A deliberate key-set change updates acceptedKeys and excludedKeysPerVariant in this suite in the same PR"
            )
        }
    }

    /// A5 — matrix completeness. A silently emptied `variants` array must red
    /// instead of turning every per-variant assertion vacuous.
    @Test
    func variantMatrixIsComplete() {
        #expect(
            Self.variants.count == 4,
            "A5 — the variant matrix must keep exactly 4 entries (found \(Self.variants.count)); the #381 presence space needs iOS canonical, macOS canonical, empty theme and empty font"
        )
        let covered = Set(Self.variants.map(\.variant))
        let missing = Set(Variant.allCases).subtracting(covered)
        #expect(
            missing.isEmpty,
            "A5 — every Variant case must have a matrix entry; missing \(missing.map(\.rawValue).sorted())"
        )
    }

    /// A6 — inventory coverage. No accepted key may be excluded from every
    /// variant (dead inventory); the union of the expected sets must be the
    /// inventory.
    @Test
    func everyAcceptedKeyIsCoveredByAtLeastOneVariant() {
        let union = Self.variants.reduce(into: Set<String>()) { $0.formUnion(Self.expectedKeys(for: $1.variant)) }
        let uncovered = Self.acceptedKeys.subtracting(union).sorted()
        #expect(
            union == Self.acceptedKeys,
            "A6 — accepted key(s) excluded from every variant: \(uncovered); a key no variant can emit is dead inventory"
        )
    }

    /// A7 — `font-family` multiplicity. A4's key-set equality cannot see a
    /// dropped fallback line (or a hardcoded duplicate family), so the append
    /// semantics are pinned for both branches.
    @Test
    func fontFamilyMultiplicityMatchesTheInputs() throws {
        // A7's `1 + macOSFallbackFontFamilies.count` formula assumes the
        // canonical primary is not also in the fallback list: the builder's
        // `sanitizedFontFamilies` dedupes, so a collision would make the
        // expected count overcount by one.
        try #require(
            !TerminalDefaults.macOSFallbackFontFamilies.contains(Self.canonicalPrimaryFontFamily),
            "A7 — the canonical primary '\(Self.canonicalPrimaryFontFamily)' must not appear in macOSFallbackFontFamilies \(TerminalDefaults.macOSFallbackFontFamilies); the `1 + count` expectation assumes a dedupe collision cannot happen"
        )
        for variant in Self.variants {
            let count = try Self.parsedDirectives(in: variant.content).filter { $0.key == "font-family" }.count
            #expect(
                count == variant.expectedFontFamilyLines,
                "A7 — \(variant.variant.displayName): expected \(variant.expectedFontFamilyLines) font-family line(s), found \(count); the macOS fallback stack appends (1 + macOSFallbackFontFamilies.count), it does not replace"
            )
        }
    }
}
