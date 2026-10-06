// SPDX-License-Identifier: MIT
//
//  GhosttyGeneratedConfigFixturePinsTests.swift
//  VVTermTests
//
//  Pins for issue #247: the fixtures under
//  `scripts/ci/fixtures/ghostty-config/` must stay byte-identical to
//  `Ghostty.ConfigBuilder.configContent` for the canonical inputs, and the
//  required `build` job must keep running
//  `scripts/ci/check-ghostty-config.sh` over that explicit fixture list. The
//  script loads the fixtures through the vendored libghostty, so a key the
//  core rejects fails CI; without this pin the fixtures could silently drift
//  from the builder and the check would validate a config the app never emits.
//
//  Fixture provenance (issue #247 plan §3.3): both fixtures were captured from
//  the pre-parameterization builder at f3a3abff and `cmp`-ed byte-equal
//  against the post-parameterization output; the macOS variant could only be
//  produced through the verification walk §3 forced-gate emulation because
//  `VVTermTests` does not compile for macOS. The `cmp` evidence lives in the
//  PR verification walk. Provenance is one step removed from this suite: the
//  byte pins prove `fixtures ≡ builder output`, and the required `build` job
//  then validates the fixtures through the vendored core (issue #247 impl
//  lens 2 M3 / lens 3 F3).
//
//  Oracle boundary (F8, #381): the checked-in probe catches keys the core
//  rejects; the core still accepts silent compatibility renames
//  (`scrollback-limit`) and duplicate keys, so that class is covered at the
//  builder boundary by `GhosttyGeneratedConfigLintTests` (inventory /
//  duplicates / known aliases) — the value-level pin in
//  `GhosttyConfigBuilderTests.configContentKeepsNonFontLinesStable` stays. A
//  core-side meaning change of a non-C-readable key (`Limit`) has no exposed
//  oracle and is tracked in issue #382; #381 is the parent.
//
//  The iOS fixture deliberately ends in `\n\n\n` (the builder's iOS template
//  emits trailing blank lines); never trim it — `git diff --check` flags it,
//  but the byte pin would red (issue #247 impl lens 3 F4).
//
//  Defeat list, stated honestly (fold round 1 closure lens N1/N3/N4). The
//  default-argument assertions are text containment over the declaration
//  region, so the same text inside a string literal in that region satisfies
//  them — a comment does not (comments are stripped before the scan, verified
//  with a comment-bearing mutant). `stepText` widens past an unnamed
//  `- uses:` step (every current step is named, so this is contrived), and
//  `canonical_theme` is duplicated between this suite and
//  `check-ghostty-config.sh`, so a one-sided edit reds the check
//  (fail-closed) rather than drifting silently. None of these can make the
//  check pass a config the core rejects; they only weaken the pin's mutation
//  coverage.
//
//  Refresh path: a builder text change regenerates both fixtures from the
//  canonical inputs in the same PR —
//    - iOS:   configContent(primaryFontFamily: "Menlo", fontSize: 13,
//             shellName: "zsh", theme: "Aizen Light", optionAsAltMode: .left)
//    - macOS: the same call with
//             fallbackFontFamilies: TerminalDefaults.macOSFallbackFontFamilies,
//             emitsPlatformInputConfig: true
//  and then re-runs `scripts/ci/check-ghostty-config.sh` over the pair.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree. The variable must actually reach the test process: on this
//  runner (iOS Simulator destination) a plain env var is inert, while
//  exporting `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` into xcodebuild's
//  own environment reaches the test process. Never set in CI.
//
//  THIS IS THE SIXTH COPY of the repository-root + comment-stripping pin
//  idiom (`repositoryRoot()` honouring `VVTERM_PINS_SOURCE_ROOT`, YAML comment
//  stripping, Swift comment stripping). Each pin file is self-contained so it
//  reverts independently until the shared helper extraction lands
//  (`WorkflowShardSplitPinsTests` re-evaluates when it passes ~1500 lines);
//  any fix to the shared idiom must be applied to all copies.
//

import Foundation
import Testing

@testable import VVTerm

struct GhosttyGeneratedConfigFixturePinsTests {

    // MARK: - Recorded constants

    private static let fixturesDirectory = "scripts/ci/fixtures/ghostty-config"
    private static let workflowPath = ".github/workflows/vvterm-pr-ci.yml"

    /// Canonical fixture inputs (issue #247 plan §3.3).
    private static let canonicalPrimaryFontFamily = "Menlo"
    private static let canonicalFontSize = 13.0
    private static let canonicalShellName = "zsh"
    private static let canonicalTheme = "Aizen Light"

    /// The exact step the required `build` job must keep (plan §3.5).
    private static let checkStepName = "Check ghostty config against the vendored core"
    private static let checkStepCommand = "run: ./scripts/ci/check-ghostty-config.sh scripts/ci/fixtures/ghostty-config/generated-ios.config scripts/ci/fixtures/ghostty-config/generated-macos.config"

    // MARK: - Fixture pins

    private static func canonicalContent(
        fallbackFontFamilies: [String],
        emitsPlatformInputConfig: Bool
    ) -> String {
        Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: canonicalPrimaryFontFamily,
            fontSize: canonicalFontSize,
            shellName: canonicalShellName,
            theme: canonicalTheme,
            optionAsAltMode: .left,
            fallbackFontFamilies: fallbackFontFamilies,
            emitsPlatformInputConfig: emitsPlatformInputConfig
        )
    }

    /// Byte-exact: the iOS fixture must equal the builder output for the iOS
    /// variant inputs (`[], false`), which are the iOS production defaults
    /// (runtime-checked in `iOSDefaultsAreEmptyAndPlatformless`). The name is
    /// variant-scoped because a later destination split could run this suite
    /// on macOS, where "production defaults" means the other branch (issue
    /// #247 impl lens 2 N1).
    @Test
    func iOSFixtureMatchesTheIOSVariantInputs() throws {
        let fixture = try Self.fixtureData("generated-ios.config")
        let generated = Self.canonicalContent(
            fallbackFontFamilies: [],
            emitsPlatformInputConfig: false
        )
        #expect(
            Data(generated.utf8) == fixture,
            "generated-ios.config drifted from ConfigBuilder's output for the canonical inputs — regenerate it in the same PR (issue #247)"
        )
    }

    /// Byte-exact: the macOS fixture must equal the builder output for the
    /// macOS production data, built on any destination (this is what proves
    /// `configContent` threads `fallbackFontFamilies` through).
    @Test
    func macOSFixtureMatchesTheProductionInputs() throws {
        let fixture = try Self.fixtureData("generated-macos.config")
        let generated = Self.canonicalContent(
            fallbackFontFamilies: TerminalDefaults.macOSFallbackFontFamilies,
            emitsPlatformInputConfig: true
        )
        #expect(
            Data(generated.utf8) == fixture,
            "generated-macos.config drifted from ConfigBuilder's output for the canonical inputs — regenerate it in the same PR (issue #247)"
        )
    }

    /// The production call site relies on the implicit platform defaults;
    /// passing those defaults explicitly must emit the same bytes.
    @Test
    func implicitPlatformDefaultsEqualExplicitPlatformDefaults() {
        let implicit = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: Self.canonicalPrimaryFontFamily,
            fontSize: Self.canonicalFontSize,
            shellName: Self.canonicalShellName,
            theme: Self.canonicalTheme,
            optionAsAltMode: .left
        )
        let explicit = Self.canonicalContent(
            fallbackFontFamilies: Ghostty.ConfigBuilder.defaultFallbackFontFamilies,
            emitsPlatformInputConfig: Ghostty.ConfigBuilder.defaultEmitsPlatformInputConfig
        )
        #expect(
            Data(implicit.utf8) == Data(explicit.utf8),
            "the implicit platform defaults and the explicit platform defaults must emit identical bytes"
        )
    }

    #if os(iOS)
    /// The iOS branch of the two defaults, runtime-checked on the destination
    /// CI actually uses; the macOS branch is source-pinned below.
    @Test
    func iOSDefaultsAreEmptyAndPlatformless() {
        #expect(Ghostty.ConfigBuilder.defaultFallbackFontFamilies.isEmpty)
        #expect(!Ghostty.ConfigBuilder.defaultEmitsPlatformInputConfig)

        let implicit = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: Self.canonicalPrimaryFontFamily,
            fontSize: Self.canonicalFontSize,
            shellName: Self.canonicalShellName,
            theme: Self.canonicalTheme,
            optionAsAltMode: .left
        )
        let explicit = Self.canonicalContent(
            fallbackFontFamilies: [],
            emitsPlatformInputConfig: false
        )
        #expect(Data(implicit.utf8) == Data(explicit.utf8))
    }
    #endif

    // MARK: - Value-mapping pins

    @Test
    func optionAsAltModesMapToThePinnedGhosttyValues() {
        #expect(Ghostty.ConfigBuilder.optionAsAltConfigValue(.none) == "false")
        #expect(Ghostty.ConfigBuilder.optionAsAltConfigValue(.left) == "left")
        #expect(Ghostty.ConfigBuilder.optionAsAltConfigValue(.right) == "right")
        #expect(Ghostty.ConfigBuilder.optionAsAltConfigValue(.both) == "true")
    }

    @Test
    func cursorStyleAndBlinkValuesArePinned() {
        let styles: [(TerminalCursorStyle, String)] = [
            (.block, "block"),
            (.bar, "bar"),
            (.underline, "underline"),
            (.blockHollow, "block_hollow"),
        ]

        for (style, ghosttyValue) in styles {
            let content = Ghostty.ConfigBuilder.configContent(
                primaryFontFamily: Self.canonicalPrimaryFontFamily,
                fontSize: Self.canonicalFontSize,
                shellName: Self.canonicalShellName,
                theme: Self.canonicalTheme,
                cursorStyle: style,
                cursorBlink: true
            )
            #expect(
                content.contains("\ncursor-style = \(ghosttyValue)\n"),
                "the emitted cursor-style line must be exactly `cursor-style = \(ghosttyValue)` — a substring match would accept `block` inside `block_hollow` (issue #247 impl lens 2 M2)"
            )
        }

        let blinking = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: Self.canonicalPrimaryFontFamily,
            fontSize: Self.canonicalFontSize,
            shellName: Self.canonicalShellName,
            theme: Self.canonicalTheme,
            cursorBlink: true
        )
        let steady = Ghostty.ConfigBuilder.configContent(
            primaryFontFamily: Self.canonicalPrimaryFontFamily,
            fontSize: Self.canonicalFontSize,
            shellName: Self.canonicalShellName,
            theme: Self.canonicalTheme,
            cursorBlink: false
        )
        #expect(blinking.contains("cursor-style-blink = true"))
        #expect(steady.contains("cursor-style-blink = false"))
    }

    // MARK: - Source pins

    /// The two `#if os(macOS)` default branches cannot be observed at runtime
    /// on the iOS Simulator destination, so their source text is pinned here:
    /// flipping a branch (`true` → `false`, `macOSFallbackFontFamilies` → `[]`)
    /// reds this test. The source is comment-stripped first so a comment that
    /// merely mentions the branch values cannot satisfy the pin.
    @Test
    func macOSDefaultBranchSourcesArePinned() throws {
        let source = Self.normalized(
            Self.strippingComments(try Self.swiftSource("VVTerm/GhosttyTerminal/Ghostty.App.swift"))
        )

        #expect(
            source.contains(Self.normalized(
                """
                        static var defaultFallbackFontFamilies: [String] {
                            #if os(macOS)
                            return TerminalDefaults.macOSFallbackFontFamilies
                            #else
                            return []
                            #endif
                        }
                """
            )),
            "the `defaultFallbackFontFamilies` macOS branch must stay `TerminalDefaults.macOSFallbackFontFamilies` (with `[]` elsewhere) — a flip changes the macOS emitted font stack (issue #247)"
        )

        #expect(
            source.contains(Self.normalized(
                """
                        static var defaultEmitsPlatformInputConfig: Bool {
                            #if os(macOS)
                            return true
                            #else
                            return false
                            #endif
                        }
                """
            )),
            "the `defaultEmitsPlatformInputConfig` macOS branch must stay `true` (with `false` elsewhere) — a flip drops or adds the `macos-option-as-alt` line (issue #247)"
        )
    }

    /// The default-argument wiring is the production call path (the app's
    /// call site in `Ghostty.App.swift` omits both arguments), and a default
    /// expression cannot be observed by any runtime assertion from this
    /// suite, so its source text is pinned. Measured before this pin: a
    /// mutant tree whose `configContent` defaults were `= []` / `= false`
    /// passed 8/8 — the same class CF-11 exists to catch, one hop upstream
    /// (issue #247 impl lens 1 finding 1).
    @Test
    func configBuilderDefaultsRemainTheProductionWiring() throws {
        let source = Self.normalized(
            Self.strippingComments(try Self.swiftSource("VVTerm/GhosttyTerminal/Ghostty.App.swift"))
        )

        guard let configContent = Self.declarationText(startingAt: "static func configContent(", in: source) else {
            throw PinFailure("could not find `static func configContent(` in Ghostty.App.swift — re-derive this pin (issue #247)")
        }
        #expect(
            configContent.contains("fallbackFontFamilies: [String] = defaultFallbackFontFamilies"),
            "`configContent` must keep `fallbackFontFamilies: [String] = defaultFallbackFontFamilies`; a platform literal here would silently drop the macOS fallback font stack (issue #247)"
        )
        #expect(
            configContent.contains("emitsPlatformInputConfig: Bool = defaultEmitsPlatformInputConfig"),
            "`configContent` must keep `emitsPlatformInputConfig: Bool = defaultEmitsPlatformInputConfig`; a platform literal here would silently drop/add the `macos-option-as-alt` line (issue #247)"
        )
        #expect(
            configContent.contains("fontFamilyLines(primaryFamily: primaryFontFamily, fallbackFamilies: fallbackFontFamilies)"),
            "`configContent` must thread `fallbackFontFamilies` through to `fontFamilyLines` — without the argument the macOS fixture cannot be generated on the iOS destination and the byte pins would bind the wrong font stack (issue #247)"
        )

        guard let fontFamilyLines = Self.declarationText(startingAt: "static func fontFamilyLines(", in: source) else {
            throw PinFailure("could not find `static func fontFamilyLines(` in Ghostty.App.swift — re-derive this pin (issue #247)")
        }
        #expect(
            fontFamilyLines.contains("fallbackFamilies: [String] = defaultFallbackFontFamilies"),
            "`fontFamilyLines` must keep `fallbackFamilies: [String] = defaultFallbackFontFamilies` (issue #247)"
        )
        #expect(
            fontFamilyLines.contains("sanitizedFontFamilies(primaryFamily: primaryFamily, fallbackFamilies: fallbackFamilies)"),
            "`fontFamilyLines` must thread `fallbackFamilies` through to `sanitizedFontFamilies` (issue #247)"
        )
    }

    // MARK: - Workflow pin

    /// The required `build` job must run the core check over the explicit
    /// fixture list, after the artifact-dependency gate and before the build
    /// starts (fail in under a second, not after a 15 m compile), and the
    /// step must live inside the `build` job: the UI shards are report-only,
    /// so a relocation would drop the enforcement while this pin stayed
    /// green (measured before the job binding landed: a step moved to
    /// `ui-tests` passed 8/8 — issue #247 impl lens 1 finding 2).
    @Test
    func buildJobRunsTheCoreConfigCheckBetweenTheGates() throws {
        let source = Self.strippingYAMLComments(try Self.swiftSource(Self.workflowPath))

        let stepOccurrences = source.components(separatedBy: "- name: \(Self.checkStepName)").count - 1
        #expect(
            stepOccurrences == 1,
            "the workflow must contain exactly one `\(Self.checkStepName)` step (found \(stepOccurrences)); without it a core-rejected key only shows up in the field (issue #247)"
        )

        guard let buildJob = Self.buildJobText(in: source) else {
            throw PinFailure("the workflow is missing the required `  build:` job — re-derive this pin (issue #247)")
        }
        let stepOccurrencesInBuildJob = buildJob.components(separatedBy: "- name: \(Self.checkStepName)").count - 1
        #expect(
            stepOccurrencesInBuildJob == 1,
            "the `\(Self.checkStepName)` step must live inside the required `build` job (found \(stepOccurrencesInBuildJob) there); the UI shards are not merge blockers, so a relocation would silently drop the check (issue #247)"
        )

        guard let checkStep = Self.stepText(named: Self.checkStepName, in: buildJob) else {
            throw PinFailure("the `build` job is missing the `\(Self.checkStepName)` step — re-derive this pin (issue #247)")
        }
        #expect(
            checkStep.contains(Self.checkStepCommand),
            "the `\(Self.checkStepName)` step must run the explicit fixture list (not a glob): `\(Self.checkStepCommand)` (issue #247)"
        )

        guard let artifactGate = buildJob.range(of: "- name: Check artifact dependencies") else {
            throw PinFailure("the `build` job is missing the `Check artifact dependencies` step (issue #316) — re-derive this pin")
        }
        guard let checkStepRange = buildJob.range(of: "- name: \(Self.checkStepName)") else {
            throw PinFailure("the `build` job is missing the `\(Self.checkStepName)` step (issue #247) — re-derive this pin")
        }
        guard let prepareStep = buildJob.range(
            of: "- name: Prepare Xcode build (mtimes, caches, Metal toolchain)",
            range: checkStepRange.upperBound..<buildJob.endIndex
        ) else {
            throw PinFailure("the `build` job is missing the `Prepare Xcode build` step after the ghostty config check — re-derive this pin")
        }

        #expect(
            artifactGate.upperBound < checkStepRange.lowerBound,
            "the ghostty config check must run after `Check artifact dependencies` (exact placement verified by the class-gate pin too)"
        )
        #expect(
            checkStepRange.upperBound < prepareStep.lowerBound,
            "the ghostty config check must run before `Prepare Xcode build`/`xcodebuild`: a rejection must fail before the compile, not after it (issue #247)"
        )
    }

    // MARK: - Filesystem helpers

    /// The text of a `static func` declaration anchored at `start`: from there
    /// to the first following `\nstatic func ` (the next declaration) or `\n}`
    /// (the enclosing enum's closing brace). Callers pass comment-stripped,
    /// normalized Swift source. Default-argument expressions cannot be
    /// observed by any runtime assertion, so their text is pinned here (issue
    /// #247 impl lens 1 finding 1).
    private static func declarationText(startingAt start: String, in source: String) -> String? {
        guard let startRange = source.range(of: start) else { return nil }
        let remainder = source[startRange.upperBound...]
        let endCandidates = ["\nstatic func ", "\n}"].compactMap { remainder.range(of: $0) }
        guard let end = endCandidates.min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(source[startRange.lowerBound...])
        }
        return String(source[startRange.lowerBound..<end.lowerBound])
    }

    /// The `  build:` job block of comment-stripped workflow YAML, up to the
    /// next two-space-indented job key (the
    /// `WorkflowArtifactDependencyClassGatePinsTests` job-block precedent).
    /// Binding the check step to this slice is what makes a relocation to a
    /// non-required job red (issue #247 impl lens 1 finding 2).
    private static func buildJobText(in workflow: String) -> String? {
        let lines = workflow.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == "  build:" }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count
        where lines[index].range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil {
            end = index
            break
        }
        guard end > start + 1 else { return nil }
        return lines[start..<end].joined(separator: "\n")
    }

    /// The step block named `name` (up to the next `- name: ` step key) from
    /// comment-stripped workflow YAML. Scoping the command assertion to the
    /// step closes the lens-1 finding-5 whole-file check.
    private static func stepText(named name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "- name: \(name)"
        }) else { return nil }
        var end = lines.count
        for index in (start + 1)..<lines.count
        where lines[index].range(of: #"^      - name: "#, options: .regularExpression) != nil {
            end = index
            break
        }
        return lines[start..<end].joined(separator: "\n")
    }

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try repositoryRoot()
            .appendingPathComponent(fixturesDirectory)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PinFailure("fixture is missing: \(url.path) — regenerate it from the canonical inputs (issue #247); this pin never skips")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw PinFailure("could not read fixture \(url.path): \(error)")
        }
    }

    private static func swiftSource(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    /// Trim each line and join, so the structural pins do not depend on the
    /// current indentation depth of the scanned declaration.
    private static func normalized(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    // MARK: - Repository root + shared comment-stripping idiom
    // (copied verbatim from WorkflowShardSplitPinsTests.swift until the shared helper extraction lands)

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the workflow/fixture mutated.
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

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Duplicated from the other workflow pin suites (each pin
    /// file is self-contained so it reverts independently until the shared
    /// helper extraction lands).
    private static func strippingYAMLComments(_ source: String) -> String {
        let characters = Array(source)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        var inSingleQuoted = false
        var inDoubleQuoted = false
        var escaped = false
        var atLineStart = true
        var previousWasWhitespace = true
        while index < characters.count {
            let character = characters[index]
            if inSingleQuoted {
                result.append(character)
                index += 1
                if character == "'" {
                    if index < characters.count, characters[index] == "'" {
                        result.append("'")
                        index += 1
                    } else {
                        inSingleQuoted = false
                    }
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if inDoubleQuoted {
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
                if character == "\"" {
                    inDoubleQuoted = false
                }
                atLineStart = false
                previousWasWhitespace = false
                continue
            }
            if character == "#", atLineStart || previousWasWhitespace {
                while index < characters.count, characters[index] != "\n" {
                    result.append(" ")
                    index += 1
                }
                continue
            }
            if character == "\n" {
                result.append("\n")
                index += 1
                atLineStart = true
                previousWasWhitespace = true
                continue
            }
            if character == "'" {
                inSingleQuoted = true
            } else if character == "\"" {
                inDoubleQuoted = true
            }
            result.append(character)
            index += 1
            atLineStart = false
            previousWasWhitespace = character.isWhitespace
        }
        return result
    }

    /// A Swift comment-stripped copy of `source`: text inside `//` line
    /// comments and nested `/* … */` block comments becomes spaces; newlines
    /// are preserved. String contents are copied verbatim (so a `//` inside a
    /// literal is not read as a comment). Duplicated from
    /// `SSHShellLoopLivenessPinsTests` (each pin file is self-contained).
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
