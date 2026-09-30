// SPDX-License-Identifier: MIT
//
//  WorkflowXcodebuildFlagPinsTests.swift
//  VVTermTests
//
//  Source pin for issue #319: the `debug-test` job's diagnostic invocation
//  passed `-collect-test-diagnostics always`, which is not a value xcodebuild
//  accepts. The step failed in ~1 s with
//
//    xcodebuild: error: option -collect-test-diagnostics requires one of two
//    values: on-failure or never
//
//  before a single test ran (acceptance run 36760904338, job `debug-test`
//  110044725147, step `Run single test with full diagnostics`). The defect was
//  latent from the job's introduction (#33) because the job had never reached
//  that step — the artifact race (#313) killed it at `Download build products`
//  first. So the pin is not "the value is on-failure": it is "every
//  `-collect-test-diagnostics` value in every workflow is one xcodebuild
//  accepts", which is the invariant the toolchain enforces and the one the
//  job's author could not see.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse the workflow as text.
//  A real YAML parse would be sounder, but a YAML toolchain (`yq`/`jq`) is not
//  guaranteed on the `xcode-27` runner (ios-adhoc-pr.yml installs jq
//  defensively) and a required job must not take a network dependency for a
//  lint. Comments are stripped YAML-style before the scan, so a
//  commented-out `# -collect-test-diagnostics always` is prose, not a flag —
//  and so the explanatory comments this pin ships with (which quote the
//  toolchain's error text) do not red it. Defeat list, stated honestly: a
//  value assembled from a shell variable (e.g.
//  `-collect-test-diagnostics "$DIAG"`) reds the pin deliberately rather than
//  passing — the pin requires a literal accepted value, so an indirect form
//  must be re-affirmed here; and a non-`-` spelling
//  (`--collect-test-diagnostics`) is not seen. The compensating control is
//  that the shape guard below fails closed if the workflow stops exposing the
//  invocation this pin exists for.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (the measured-working form is
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` exported into xcodebuild's own
//  environment). Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowXcodebuildFlagPinsTests {

    /// The values Xcode 26.3's `xcodebuild` accepts for this option, from its
    /// own rejection of anything else (measured locally and on the runner):
    /// "option -collect-test-diagnostics requires one of two values:
    /// on-failure or never".
    private static let acceptedDiagnosticValues: Set<String> = ["on-failure", "never"]

    // MARK: - Tests

    /// No workflow may pass a `-collect-test-diagnostics` value xcodebuild
    /// rejects — the failure mode is a step that dies in ~1 s without running
    /// a test, which reads like a test problem rather than a usage error.
    @Test
    func testEveryCollectTestDiagnosticsValueIsAcceptedByXcodebuild() throws {
        let occurrences = try Self.collectTestDiagnosticsOccurrences()

        #expect(
            !occurrences.isEmpty,
            "no `-collect-test-diagnostics` flag was found in any workflow — re-derive this pin (issue #319)"
        )

        let badValues = occurrences.filter { !Self.acceptedDiagnosticValues.contains($0.value) }
        #expect(
            badValues.isEmpty,
            """
            every `-collect-test-diagnostics` value must be one xcodebuild accepts \
            (on-failure or never); xcodebuild rejects anything else with "option \
            -collect-test-diagnostics requires one of two values: on-failure or never" and the \
            step fails before running a test (issue #319). Offending: \
            \(badValues.map { "\($0.file):\($0.line) -> \($0.value)" }.sorted().joined(separator: ", "))
            """
        )

        // Positive controls: the scan reached the real invocations. `never` is
        // the normal CI path's deliberate value (#251) and `on-failure` is the
        // debug job's (#319), so both must be present in the corpus.
        let values = Set(occurrences.map(\.value))
        #expect(
            values.contains("never"),
            "the scan must see the normal CI path's `never` value (#251) — re-derive this pin"
        )
        #expect(
            values.contains("on-failure"),
            "the scan must see the debug job's `on-failure` value (#319) — re-derive this pin"
        )
    }

    /// The shape guard: the `debug-test` job must still be present, must still
    /// invoke `xcodebuild`, and must carry an accepted diagnostic value at its
    /// own invocation. Without this, the scan above could keep passing while
    /// the job it exists for silently disappeared.
    @Test
    func testTheDebugTestJobInvokesXcodebuildWithAnAcceptedDiagnosticValue() throws {
        let source = try Self.workflowSource(".github/workflows/vvterm-pr-ci.yml")
        let stripped = Self.strippingYAMLComments(source)
        let lines = stripped.components(separatedBy: "\n")

        let jobIndex = try #require(
            lines.firstIndex { $0.range(of: #"^  debug-test:\s*$"#, options: .regularExpression) != nil },
            "the workflow must contain a `  debug-test:` job — re-derive this pin (issue #319)"
        )
        let jobLines = Array(lines[jobIndex...])

        #expect(
            jobLines.contains { $0.contains("xcodebuild test-without-building") },
            "the debug-test job must still invoke `xcodebuild test-without-building` — re-derive this pin (issue #319)"
        )
        #expect(
            jobLines.contains { $0.contains("Run single test with full diagnostics") },
            "the debug-test job must still run the single test with full diagnostics — re-derive this pin (issue #319)"
        )
        #expect(
            jobLines.contains { line in
                line.range(
                    of: #"-collect-test-diagnostics\s+on-failure\b"#,
                    options: .regularExpression
                ) != nil
            },
            "the debug-test invocation must pass `-collect-test-diagnostics on-failure`: this job is dispatched to investigate a failure, so its diagnostics are collected on failure; `never` is the normal path's deliberate value (#251) and `always` is not a value at all (issue #319)"
        )
    }

    // MARK: - Fixtures

    private struct FlagOccurrence {
        let file: String
        let line: Int
        let value: String
    }

    private static func collectTestDiagnosticsOccurrences() throws -> [FlagOccurrence] {
        let directory = try repositoryRoot().appendingPathComponent(".github/workflows")
        let files: [String]
        do {
            files = try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
                .sorted()
        } catch {
            throw PinFailure("could not list the workflows at \(directory.path): \(error) — re-derive this pin")
        }
        guard !files.isEmpty else {
            throw PinFailure("no workflow files found at \(directory.path) — re-derive this pin")
        }

        var occurrences: [FlagOccurrence] = []
        for file in files {
            let source = try workflowSource(".github/workflows/\(file)")
            let stripped = Self.strippingYAMLComments(source)
            for (index, line) in stripped.components(separatedBy: "\n").enumerated() {
                guard let range = line.range(
                    of: #"-collect-test-diagnostics\s+(\S+)"#,
                    options: .regularExpression
                ) else { continue }
                let match = String(line[range])
                let value = match
                    .components(separatedBy: .whitespaces)
                    .last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\\")) ?? ""
                occurrences.append(FlagOccurrence(file: file, line: index + 1, value: value))
            }
        }
        return occurrences
    }

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    private static func workflowSource(_ relativePath: String) throws -> String {
        let url = try repositoryRoot().appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read \(relativePath) at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with a workflow mutated.
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
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` inside a scalar is not
    /// read as a comment. Duplicated from `WorkflowArtifactDependencyPinsTests`
    /// (each pin file is self-contained so it reverts independently).
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
                        // YAML single-quote escape: `''` stays inside the scalar.
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
}
