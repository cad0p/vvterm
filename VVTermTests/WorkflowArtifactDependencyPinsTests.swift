// SPDX-License-Identifier: MIT
//
//  WorkflowArtifactDependencyPinsTests.swift
//  VVTermTests
//
//  Source pins for issue #313: the `debug-test` job extracts the
//  `vvterm-build` artifact that the `build` job uploads from the same run, so
//  it must declare `needs: build`. Without the dependency a dispatch starts
//  both jobs together and the download races the upload: run 36727783272's
//  `Download build products` step failed at 14:16:45Z with "Artifact not
//  found for name: vvterm-build", ~9 minutes before the upload even started,
//  and every later step (including the diagnostic test run) was skipped.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse the workflow as text.
//  A real YAML parse would be sounder, but a YAML toolchain (`yq`/`jq`) is not
//  guaranteed on the `xcode-27` runner (ios-adhoc-pr.yml installs jq
//  defensively) and a required job must not take a network dependency for a
//  lint. The compensating controls are: (a) comments are stripped YAML-style
//  before every scan, so a commented-out `# needs: build` cannot satisfy the
//  dependency pin; (b) the key is anchored at job indent 4 with `$`, so a
//  `run:` script literal at step indent cannot satisfy it; (c) the second test
//  fails closed when the job blocks stop parsing in the canonical shape, so a
//  quoted key that would merge blocks cannot silently corrupt the first
//  test's slice.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (measured per pin in the #313 PR report). The variable must
//  actually reach the test process: on this runner (measured 2026-09-29/30,
//  iOS Simulator destination) a plain env var is inert, while exporting
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into xcodebuild's own
//  environment reaches the test process. Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowArtifactDependencyPinsTests {

    private static let workflowPath = ".github/workflows/vvterm-pr-ci.yml"

    // MARK: - Tests

    /// The regression pin: `debug-test` declares the dependency on the job
    /// that produces its artifact, and still downloads that artifact.
    @Test
    func testDebugTestJobDependsOnTheBuildThatUploadsItsArtifact() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let job = try Self.jobBlock(named: "debug-test", in: stripped)

        // 1. A comment-stripped job-level `needs: build` key at indent 4.
        //    `# needs: build` is removed by comment stripping; a
        //    `run: echo '… needs: build'` literal sits at step indent and
        //    cannot match the anchored pattern.
        #expect(
            job.text.range(of: #"(?m)^    needs:\s*build\s*$"#, options: .regularExpression) != nil,
            "the debug-test job must declare `needs: build` (the canonical spelling) so its `vvterm-build` download cannot race the upload; a `needs: [build]` list form also reds this pin — re-affirm the dependency and the spelling (issue #313)"
        )

        // 2. Exactly one step anchored on `uses: actions/download-artifact`
        //    (the bare string also appears in a ui-tests comment), and that
        //    step requests the `vvterm-build` artifact.
        let steps = Self.stepBlocks(in: job)
        let downloadSteps = steps.filter { step in
            step.contains { line in
                line.range(of: #"^\s*uses:\s*actions/download-artifact\b"#, options: .regularExpression) != nil
            }
        }
        #expect(
            downloadSteps.count == 1,
            "the debug-test job must contain exactly one `uses: actions/download-artifact` step (found \(downloadSteps.count))"
        )
        let downloadStep = try #require(
            downloadSteps.first,
            "the debug-test job must contain a `uses: actions/download-artifact` step"
        )
        #expect(
            downloadStep.contains { line in
                line.range(of: #"^\s*name:\s*vvterm-build\s*$"#, options: .regularExpression) != nil
            },
            "the download-artifact step must request the `vvterm-build` artifact (issue #313)"
        )

        // 3. Positive controls: the pin resolved the real debug-test job, not
        //    an empty or shifted slice.
        #expect(
            job.text.contains("Run single test with full diagnostics"),
            "the debug-test job must still run the single test with full diagnostics"
        )
        #expect(
            job.text.contains("timeout-minutes: 45"),
            "the debug-test job must still declare its 45-minute timeout"
        )

        // 4. The legible-failure package (issue #313): a dispatch must still
        //    evaluate this job when `build` failed — the explicit status
        //    functions keep GitHub from skipping it silently on a failed
        //    dependency — with the same event gate as before.
        let normalized = job.text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        #expect(
            normalized.contains(
                "always() && !cancelled() && github.event_name == 'workflow_dispatch' && github.event.inputs.debug_test != ''"
            ),
            "the debug-test job must keep the dispatch gate `always() && !cancelled() && github.event_name == 'workflow_dispatch' && github.event.inputs.debug_test != ''`; without `always()` (and `!cancelled()`) a failed `build` silently skips this job and hides the missing artifact (issue #313)"
        )

        // 5. The first step must fail by name when the producer did not
        //    succeed, before anything downloads.
        let guardStep = try #require(
            steps.first { step in
                step.first?.range(
                    of: #"^      - name: Require the build artifact \(#313\)\s*$"#,
                    options: .regularExpression
                ) != nil
            },
            "the debug-test job must contain a `Require the build artifact (#313)` step so a failed producer fails this job by name (issue #313)"
        )
        #expect(
            guardStep.contains { line in
                line.range(of: #"^\s*if:\s*needs\.build\.result\s*!=\s*'success'\s*$"#, options: .regularExpression) != nil
            },
            "the `Require the build artifact (#313)` step must run on `needs.build.result != 'success'` so it fires exactly when the producer did not succeed (issue #313)"
        )
    }

    /// The pin's own soundness guard: if the workflow stops parsing into the
    /// canonical job-block shape, the first test's slice can no longer be
    /// trusted — fail closed and ask for a re-derivation.
    @Test
    func testWorkflowJobBlocksParseInTheCanonicalShape() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let blocks = try Self.jobBlocks(in: stripped)

        #expect(!blocks.isEmpty, "the workflow must contain at least one job block")

        for block in blocks {
            #expect(
                Self.isCanonicalJobKey(block.key),
                "the workflow's job syntax changed — re-derive this pin"
            )
            #expect(
                block.lines.contains { line in
                    line.range(of: #"^    steps:\s*$"#, options: .regularExpression) != nil
                },
                "the workflow's job syntax changed — re-derive this pin"
            )
        }
    }

    // MARK: - Fixtures

    private struct JobBlock {
        /// The job's key line, e.g. `  debug-test:`.
        let key: String
        let lines: [String]

        var text: String { lines.joined(separator: "\n") }
    }

    private struct PinFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) { self.description = description }
    }

    private static func workflowSource() throws -> String {
        let url = try repositoryRoot().appendingPathComponent(workflowPath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PinFailure("could not read the workflow at \(url.path): \(error)")
        }
    }

    private static func repositoryRoot() throws -> URL {
        // Counterfactual hook: the mutation runs point this at a copy of the
        // source with the workflow mutated. The measured-working form is
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

    // MARK: - Workflow parsing

    /// The lines of the workflow after the top-level `jobs:` key.
    private static func jobsRegion(in workflow: String) throws -> [String] {
        let lines = workflow.components(separatedBy: "\n")
        let jobsIndex = try #require(
            lines.firstIndex { line in
                line.range(of: #"^jobs:\s*$"#, options: .regularExpression) != nil
            },
            "the workflow must have a top-level `jobs:` key"
        )
        let region = Array(lines[(jobsIndex + 1)...])
        guard !region.isEmpty else {
            throw PinFailure("the workflow's `jobs:` section is empty — re-derive this pin")
        }
        return region
    }

    /// Slices the jobs region into one block per job. A block starts at any
    /// line indented two spaces and ending in `:` — including a quoted key
    /// (`  "tail-job":`), so a malformed key becomes its own block and the
    /// shape guard sees it, instead of silently merging into its neighbour.
    private static func jobBlocks(in workflow: String) throws -> [JobBlock] {
        let region = try jobsRegion(in: workflow)
        let delimiter = #"^  \S.*:\s*$"#
        var starts: [Int] = []
        for (index, line) in region.enumerated() {
            if line.range(of: delimiter, options: .regularExpression) != nil {
                starts.append(index)
            }
        }
        guard let firstStart = starts.first else {
            throw PinFailure("the workflow's job syntax changed — re-derive this pin")
        }
        for index in 0..<firstStart {
            guard region[index].trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PinFailure("the workflow's job syntax changed — re-derive this pin")
            }
        }
        var blocks: [JobBlock] = []
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : region.count
            let lines = Array(region[start..<end])
            blocks.append(JobBlock(key: lines[0], lines: lines))
        }
        return blocks
    }

    private static func jobBlock(named name: String, in workflow: String) throws -> JobBlock {
        let blocks = try jobBlocks(in: workflow)
        let matches = blocks.filter { $0.key.trimmingCharacters(in: .whitespaces) == "\(name):" }
        #expect(
            matches.count == 1,
            "the workflow must contain exactly one `\(name):` job block (found \(matches.count) of \(blocks.count) blocks)"
        )
        return try #require(
            matches.first,
            "the workflow must contain a `\(name):` job block"
        )
    }

    private static func isCanonicalJobKey(_ line: String) -> Bool {
        line.range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil
    }

    /// Slices a job block into its steps. A step starts at a line indented six
    /// spaces followed by `- `; job-level keys before the first step are not
    /// part of any step.
    private static func stepBlocks(in job: JobBlock) -> [[String]] {
        let stepStart = #"^      -\s"#
        var steps: [[String]] = []
        var current: [String] = []
        for line in job.lines {
            if line.range(of: stepStart, options: .regularExpression) != nil {
                if !current.isEmpty { steps.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` or a `needs: build`
    /// literal inside a scalar is not read as a comment.
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
