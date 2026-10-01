// SPDX-License-Identifier: MIT
//
//  WorkflowPerPREventGatePinsTests.swift
//  VVTermTests
//
//  Source pins for issue #315: the per-PR jobs (`wait-for-ota-publish`,
//  `unit-tests`, `ui-tests`) must be event-gated so a `workflow_dispatch` with
//  `debug_test` set runs exactly `build` + `debug-test` — 2 macOS jobs at peak
//  1 — instead of the whole per-PR matrix (7 macOS jobs against the account's
//  5-concurrent-macOS-job cap, AGENTS.md CI Performance Budget). The gate is
//  the compound spelling
//
//      if: github.event_name == 'pull_request' || github.event.inputs.debug_test == ''
//
//  at job indent 4. The second clause preserves the documented empty-input
//  dispatch (measured: run 35906201179 was a dispatch with `debug_test`
//  skipped that ran the full matrix), which is also the LPT sampling route.
//
//  CLASS PIN: `testEveryJobExceptBuildAndDebugTestIsGated` iterates every job
//  block and requires the gate on all of them except the two commented
//  exemptions. Without it a newly added ungated job silently re-breaks #315's
//  acceptance (measured: a `lint-headers:` mutant left the three per-job pins
//  green). The exempt list is the deliberate seam: putting a job back on the
//  dispatch path requires editing it AND the AGENTS.md cap narrative.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse the workflow as text
//  (the same trade-off recorded in `WorkflowArtifactDependencyPinsTests`). A
//  real YAML parse would be sounder, but a YAML toolchain (`yq`/`jq`) is not
//  guaranteed on the `xcode-27` runner and a required job must not take a
//  network dependency for a lint. Compensating controls: (a) comments are
//  stripped YAML-style before every scan, so a commented-out gate cannot
//  satisfy a pin; (b) the gate regex is anchored at job indent 4 with `$` and
//  uses `[ \t]*` rather than `\s*`, so a two-line plain scalar reds as a
//  spelling tripwire; (c) the last test fails closed when the job blocks stop
//  parsing in the canonical shape.
//
//  Defeat list, stated honestly (the #319 idiom): the pin recognizes the gate
//  only as the literal compound clause at job indent 4.
//   - a `${{ }}`-wrapped expression, a quoted `"if":` key, reordered operands,
//     a two-line plain scalar, and a step-level, matrix-level or hoisted
//     (`vars.…` / `env.…`) gate all RED by design on the per-PR jobs: the
//     literal clause must appear, so an indirect spelling is a visible tripwire
//     rather than a silent pass. On `build` a step-level `if:` is allowed by
//     design — that pin asserts the absence of any *job-level* gate.
//   - a YAML anchor on a job key (`  lint-headers: &lint`) is now sliced as
//     its own block, so the canonical-shape test rejects it and the class pin
//     cannot miss it (measured GREEN before that guard — lens 2 MINOR-4). A
//     YAML alias standing in for the gate value REDs: the literal clause must
//     appear.
//   - a quoted job key (`  "lint-headers":`) or a job without a `steps:` line
//     REDs the canonical-shape test.
//   - no pin here reads `on:` or `uses:`, so a gate introduced by a second
//     workflow file or a reusable-workflow call is out of scope by
//     construction. It cannot silently weaken these pins, because the file
//     parsed here is the one the PR trigger runs.
//
//  The executed count this suite reports is the Swift Testing line (`Test run
//  with N tests in M suites …`). The XCTest wrapper's `Executed 0 tests` line
//  is bundle bookkeeping for a bundle that contains only Swift Testing suites,
//  not the suite's signal.
//
//  Provenance: this is the THIRD copy of the `JobBlock` parser idiom
//  (`repositoryRoot()` honouring `VVTERM_PINS_SOURCE_ROOT`, YAML comment
//  stripping, `jobBlocks(in:)`, `jobBlock(named:)`, `jobName(of:)`) — after
//  `WorkflowArtifactDependencyPinsTests` and `WorkflowXcodebuildFlagPinsTests`
//  — because each pin file is self-contained so it reverts independently. A
//  parser fix must be applied to all three copies until a fourth pin file
//  justifies extracting a shared helper.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (measured per pin in the #315 PR report). The variable must
//  actually reach the test process: on this runner (measured 2026-09-29/30,
//  iOS Simulator destination) a plain env var is inert, while exporting
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<mutated tree>` into xcodebuild's own
//  environment reaches the test process. Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowPerPREventGatePinsTests {

    private static let workflowPath = ".github/workflows/vvterm-pr-ci.yml"

    /// The exact compound-gate spelling at job indent 4. `[ \t]*` (not `\s*`)
    /// makes a two-line plain-scalar respelling red instead of silently
    /// changing the gate's YAML type.
    private static let compoundGatePattern = #"(?m)^    if:[ \t]*github\.event_name == 'pull_request' \|\| github\.event\.inputs\.debug_test == ''[ \t]*$"#

    /// The #313 dispatch gate on `debug-test`, anchored to the job-level line.
    private static let debugTestGatePattern = #"(?m)^    if:[ \t]*always\(\) && !cancelled\(\) && github\.event_name == 'workflow_dispatch' && github\.event\.inputs\.debug_test != ''[ \t]*$"#

    // MARK: - Tests

    /// The regression pin: the three per-PR jobs carry the exact compound gate.
    @Test
    func testPerPRJobsCarryTheCompoundEventGate() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)

        let expectations: [(job: String, control: String)] = [
            ("wait-for-ota-publish", "Wait for the OTA publish to start"),
            ("unit-tests", "Run unit tests (VVTermTests)"),
            ("ui-tests", "Run UI tests (shard ${{ matrix.shard.name }})"),
        ]
        for expectation in expectations {
            let job = try Self.jobBlock(named: expectation.job, in: stripped)
            #expect(
                job.text.range(of: Self.compoundGatePattern, options: .regularExpression) != nil,
                "the `\(expectation.job)` job must carry the exact compound gate `if: github.event_name == 'pull_request' || github.event.inputs.debug_test == ''` at job indent 4 (issue #315); the second clause preserves the empty-input dispatch mode, which runs the full per-PR matrix on demand"
            )
            #expect(
                job.text.contains(expectation.control),
                "the pin resolved the real `\(expectation.job)` job, not an empty or shifted slice (missing positive control: `\(expectation.control)`)"
            )
        }
    }

    /// The class pin: every job except the two commented exemptions is gated,
    /// so a newly added job cannot silently re-break #315.
    @Test
    func testEveryJobExceptBuildAndDebugTestIsGated() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let blocks = try Self.jobBlocks(in: stripped)

        // Exemptions, each deliberate:
        //  - `build` is ungated because `debug-test` consumes its `vvterm-build`
        //    artifact on every dispatch (issue #313).
        //  - `debug-test` is the dispatch-only diagnostic job; its own #313 gate
        //    runs it exactly on a non-empty `debug_test` (issue #315).
        let exempt: Set<String> = ["build", "debug-test"]

        for block in blocks {
            let name = Self.jobName(of: block)
            if exempt.contains(name) { continue }
            #expect(
                block.text.range(of: Self.compoundGatePattern, options: .regularExpression) != nil,
                "the `\(name)` job is not gated for issue #315, so it would run (and burn a macOS slot) on a debug dispatch. If it belongs on the dispatch path, add it to the exempt list in this pin AND update the AGENTS.md CI Performance Budget — do not just delete this assertion"
            )
        }
    }

    /// `build` must stay ungated — **no job-level `if:` at all**, not merely
    /// none naming the pull_request event: `debug-test` consumes its artifact
    /// on every dispatch (issue #313), and any job-level gate on `build` skips
    /// it on some path (`github.event.inputs.debug_test == ''` skips it on a
    /// debug dispatch and fails the #313 guard; `if: false` breaks every
    /// path). Lens 2 measured the narrower assertion green for all of those.
    @Test
    func testBuildJobHasNoJobLevelGate() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let job = try Self.jobBlock(named: "build", in: stripped)

        // Anchored at job indent 4, so an unrelated step-level `if:` inside the
        // block (e.g. `if: failure()` on an upload step) does not false-red
        // this pin.
        #expect(
            job.text.range(of: #"(?m)^    if:"#, options: .regularExpression) == nil,
            "the `build` job must carry no job-level `if:` at all (issue #315): `debug-test` downloads the `vvterm-build` artifact from this job on every dispatch (issue #313), so any job-level gate skips `build` on some path and breaks the run. Step-level conditionals inside the job are fine; only the job-level key is forbidden."
        )
        #expect(
            job.text.contains("Build for iOS Simulator (build-for-testing)"),
            "the pin resolved the real `build` job, not an empty or shifted slice"
        )
    }

    /// `debug-test` keeps the #313 dispatch gate verbatim.
    @Test
    func testDebugTestJobKeepsItsDispatchGate() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let job = try Self.jobBlock(named: "debug-test", in: stripped)

        #expect(
            job.text.range(of: Self.debugTestGatePattern, options: .regularExpression) != nil,
            "the `debug-test` job must keep the #313 dispatch gate `always() && !cancelled() && github.event_name == 'workflow_dispatch' && github.event.inputs.debug_test != ''` at job indent 4; `always()` keeps a failed build legible, and the non-empty clause is the only thing that runs this job (issues #313, #315)"
        )
        #expect(
            job.text.contains("Run single test with full diagnostics"),
            "the pin resolved the real `debug-test` job, not an empty or shifted slice"
        )
    }

    /// The pin's own soundness guard: if the workflow stops parsing into the
    /// canonical job-block shape, the other tests' slices can no longer be
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

    /// The `wait-for-ota-publish` script must exit before its first lookup
    /// when `HEAD_SHA` is empty. A dispatch carries no PR head, and
    /// `gh run list --commit ""` ignores the empty filter and returns
    /// repo-wide PR-event runs — measured on the #313 acceptance dispatch
    /// (run 36776953839, log lines 105-108), which resolved an unrelated PR's
    /// `OTA archive run: 36770666977` + `Publish run: 36771788878` and
    /// released in 10 s only because that foreign publish had already started
    /// 38 minutes earlier. Had it been in flight, `unit-tests` would have
    /// waited on it (worst case the gate job's 45-minute timeout). The guard
    /// is a no-op on the PR path, where the head SHA is always set.
    @Test
    func testOTAPublishGateSkipsImmediatelyWhenHeadSHAIsEmpty() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let job = try Self.jobBlock(named: "wait-for-ota-publish", in: stripped)

        let guardRange = job.text.range(
            of: #"if \[\[ -z "\$HEAD_SHA" \]\]"#,
            options: .regularExpression
        )
        #expect(
            guardRange != nil,
            "the `wait-for-ota-publish` script must guard an empty `HEAD_SHA` (`if [[ -z \"$HEAD_SHA\" ]]`) at the top of its step script: a dispatch has no PR head and `gh run list --commit \"\"` ignores the empty filter, so the gate would bind to an unrelated PR's OTA run (measured on run 36776953839)"
        )
        let firstLookup = job.text.range(of: "gh run list")
        #expect(
            firstLookup != nil,
            "the `wait-for-ota-publish` script must still resolve its OTA run with `gh run list`"
        )
        if let guardRange, let firstLookup {
            #expect(
                guardRange.upperBound <= firstLookup.lowerBound,
                "the empty-`HEAD_SHA` guard must run before the first `gh run list` in the `wait-for-ota-publish` script, otherwise the empty `--commit` filter still returns repo-wide OTA runs"
            )
        }
        #expect(
            job.text.contains("::notice::workflow_dispatch has no PR head"),
            "the empty-`HEAD_SHA` guard must emit its skip notice so the dispatch log says why the gate did not wait"
        )
        #expect(
            job.text.contains("Wait for the OTA publish to start"),
            "the pin resolved the real `wait-for-ota-publish` job, not an empty or shifted slice"
        )
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
    /// (`  "tail-job":`) or an anchored key (`  lint-headers: &lint`), so a
    /// malformed key becomes its own block and the shape guard sees it,
    /// instead of silently merging into its neighbour (lens 2 MINOR-4).
    private static func jobBlocks(in workflow: String) throws -> [JobBlock] {
        let region = try jobsRegion(in: workflow)
        let delimiter = #"^  \S.*:\s*(?:&[^\s]+)?\s*$"#
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
        let matches = blocks.filter { Self.jobName(of: $0) == name }
        #expect(
            matches.count == 1,
            "the workflow must contain exactly one `\(name):` job block (found \(matches.count) of \(blocks.count) blocks)"
        )
        return try #require(
            matches.first,
            "the workflow must contain a `\(name):` job block"
        )
    }

    /// The job's bare name, e.g. `wait-for-ota-publish`. Splits at the first
    /// colon so an anchored key (`lint-headers: &lint`) still yields the name
    /// the class pin's exempt list compares against; the canonical-shape
    /// guard is what rejects the anchor itself.
    private static func jobName(of block: JobBlock) -> String {
        let key = block.key.trimmingCharacters(in: .whitespaces)
        if let colon = key.firstIndex(of: ":") {
            return String(key[..<colon])
        }
        return key
    }

    private static func isCanonicalJobKey(_ line: String) -> Bool {
        line.range(of: #"^  [A-Za-z0-9_-]+:\s*$"#, options: .regularExpression) != nil
    }

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` or a gate literal inside
    /// a scalar is not read as a comment. Duplicated from
    /// `WorkflowArtifactDependencyPinsTests` (each pin file is self-contained
    /// so it reverts independently).
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
