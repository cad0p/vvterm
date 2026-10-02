// SPDX-License-Identifier: MIT
//
//  WorkflowArtifactDependencyClassGatePinsTests.swift
//  VVTermTests
//
//  Source pins for issue #316: the artifact-dependency gate is a fail-closed
//  subset YAML parser wired into the REQUIRED `build` job. The class rule
//  existed as a site pin after #313 (`WorkflowArtifactDependencyPinsTests`),
//  but the #313 fold measured that a text-window pin is unsound (a quoted key
//  merges YAML blocks) and that `Process`-driven execution cannot run in CI
//  (the test bundle only runs on the iOS Simulator, where `Process` does not
//  exist — plan v2 recheck). So these pins are iOS-safe SOURCE pins only:
//
//    P1  the gate script, its SPDX header, the fixtures directory and the
//        manifest exist;
//    P2  the required `build` job runs the gate immediately after the license
//        gate, with the preflight, `--selftest` and the scan in that order,
//        and the `run:` block asserted EXACTLY (whitespace-normalized), so an
//        appended `|| true`, a reordering, a step-level `if:` /
//        `continue-on-error:`, or a job-level `if:` / `continue-on-error:` on
//        `build` (a skipped required job still reports success) breaks the
//        pin;
//    P3  the workflow still parses into the canonical job/step shape (shape
//        guard: without it, P2 could slice an empty or shifted step);
//    P4  the fixture inventory covers every case the class rule exists for,
//        each fixture is referenced by the manifest, and the script's
//        manifest-length and scan-floor constants are pinned to their VALUES
//        (case count and floor), so a stale constant reds here too;
//    P5  the §4.4 diagnostic format strings are present as CODE (comments are
//        stripped first), so the diagnostics the manifest compares cannot be
//        quietly reworded.
//
//  FORMATTING HEURISTIC, NOT A PROOF: this file parses the workflow as text
//  (the same trade-off recorded in the other workflow pin suites). The gate
//  itself is the structural check; these pins guard its wiring and contract.
//
//  Provenance: this is the FOURTH copy of the `JobBlock` parser idiom
//  (`repositoryRoot()` honouring `VVTERM_PINS_SOURCE_ROOT`, YAML comment
//  stripping, `jobBlocks(in:)`, `jobBlock(named:)`, `jobName(of:)`,
//  `stepBlocks(in:)`) — after `WorkflowArtifactDependencyPinsTests`,
//  `WorkflowXcodebuildFlagPinsTests` and `WorkflowPerPREventGatePinsTests` —
//  because each pin file is self-contained so it reverts independently. A
//  parser fix must be applied to all four copies until a fifth pin file
//  justifies extracting a shared helper.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree. The variable must actually reach the test process: on this
//  runner (measured 2026-09-29/30, iOS Simulator destination) a plain env var
//  is inert, while exporting `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` into
//  xcodebuild's own environment reaches the test process. Never set in CI.
//

import Foundation
import Testing

@testable import VVTerm

struct WorkflowArtifactDependencyClassGatePinsTests {

    private static let workflowPath = ".github/workflows/vvterm-pr-ci.yml"
    private static let scriptPath = "scripts/ci/check-artifact-dependencies.py"
    private static let fixturesDirectory = "scripts/ci/fixtures/artifact-dependency"
    private static let manifestPath = "scripts/ci/fixtures/artifact-dependency/manifest.py"

    /// The exact whitespace-normalized step block. Every element the required
    /// `build` job must run, in order, with no conditionals and no `|| true`.
    private static let expectedStepBlock = """
        - name: Check artifact dependencies run: | set -euo pipefail command -v python3 >/dev/null || { echo "::error::python3 not found — the artifact-dependency gate needs it"; exit 1; } python3 scripts/ci/check-artifact-dependencies.py --selftest python3 scripts/ci/check-artifact-dependencies.py
        """

    /// P4's value pins (lens-2 NIT 1): the fixture-manifest case count and
    /// the scanned-workflow floor. A stale constant must red the pin, not
    /// only the build-time `--selftest`/scan.
    private static let expectedManifestCases = 143
    private static let expectedWorkflowFloor = 12

    /// The `build` job's exact job-level key set (round-2 C-NIT-1). A
    /// job-level condition on the required job can skip the gate while
    /// GitHub still reports success; asserting the whole key set closes the
    /// class for every spelling (`if:`, `if :`, `"if":`, `continue-on-error`,
    /// or a new key) in one comparison instead of a regex per spelling.
    private static let expectedBuildJobKeys: Set<String> = [
        "runs-on",
        "timeout-minutes",
        "env",
        "steps",
    ]

    /// Every fixture the plan requires (accept controls, measured holes, and
    /// refusal controls). The manifest must reference each one, and each file
    /// must exist, so deleting a fixture (or its case) is visible here.
    private static let requiredFixtures: [String] = [
        // accept controls
        "accept-needs-flow.yml",
        "accept-needs-bare.yml",
        "accept-needs-after-steps.yml",
        "accept-needs-same-indent.yml",
        "accept-needs-quoted.yml",
        "accept-bom-quoted-jobs.yml",
        "accept-templated-upload.yml",
        "accept-producer-is-consumer.yml",
        "accept-cross-run-run-id.yml",
        "accept-block-scalar.yml",
        "accept-quoted-uses.yml",
        "accept-run-id-with-needs.yml",
        "accept-token-in-comment.yml",
        "accept-quote-in-run-body.yml",
        "accept-deep-with.yml",
        "accept-needs-block-with-comment.yml",
        "accept-quoted-plain-uses.yml",
        "accept-run-id-static-cross-run-env.yml",
        "accept-run-line-mentioning-action.yml",
        "accept-run-id-cross-run-with-token.yml",
        "accept-job-key-mentioning-action.yml",
        "accept-step-name-mentioning-action.yml",
        "accept-job-id-containing-token-needs-flow.yml",
        "accept-job-id-containing-token-needs-block.yml",
        "accept-job-id-containing-token-if-expr.yml",
        "accept-legal-escape-in-name.yml",
        "accept-legal-escape-in-run.yml",
        // rule violations
        "reject-missing-edge.yml",
        "reject-shadow-downloader.yml",
        "reject-wrong-job-needs.yml",
        "reject-steps-at-key-indent.yml",
        "reject-steps-at-eight.yml",
        "reject-job-body-at-six.yml",
        "reject-run-block-decoy.yml",
        "reject-run-single-line-decoy.yml",
        "reject-quoted-uses-no-edge.yml",
        "reject-case-variant-action.yml",
        "reject-quoted-job-key-merge.yml",
        "reject-nested-needs-in-matrix.yml",
        "reject-run-id-current.yml",
        "reject-run-id-fallback.yml",
        "reject-run-id-bracket.yml",
        "reject-quoted-jobs-missing-edge.yml",
        "reject-crlf-missing-edge.yml",
        "reject-yaml-extension.yaml",
        "reject-quoted-escape-uses.yml",
        "reject-quoted-escape-keyed-uses.yml",
        "reject-block-scalar-uses.yml",
        "reject-block-scalar-uses-folded.yml",
        "reject-block-scalar-with-name.yml",
        "reject-block-scalar-needs.yml",
        "reject-run-id-env-indirection.yml",
        "reject-run-id-cross-run-without-token.yml",
        "reject-block-scalar-with-run-id.yml",
        "reject-block-scalar-with-pattern.yml",
        "reject-block-scalar-with-artifact-ids.yml",
        "reject-producer-is-consumer-download-first.yml",
        "reject-orphan-download.yml",
        // refusals
        "reject-cross-file-a.yml",
        "reject-cross-file-b.yml",
        "reject-unterminated-quote.yml",
        "reject-terminated-multiline-quote.yml",
        "reject-split-uses.yml",
        "reject-template-name-download.yml",
        "reject-pattern-download.yml",
        "reject-artifact-ids-download.yml",
        "reject-download-no-with.yml",
        "reject-run-id-empty.yml",
        "reject-run-id-unrecognized.yml",
        "reject-duplicate-producer.yml",
        "reject-duplicate-steps.yml",
        "reject-duplicate-job-name.yml",
        "reject-duplicate-top-level-jobs.yml",
        "reject-duplicate-with-name.yml",
        "reject-absent-jobs.yml",
        "reject-empty-jobs.yml",
        "reject-tabs.yml",
        "reject-merge-key.yml",
        "reject-anchor-alias.yml",
        "reject-flow-step.yml",
        "reject-flow-with.yml",
        "reject-uses-job-with-steps.yml",
        "reject-nested-with-lookalike.yml",
        "reject-unconsumed-line.yml",
        "reject-scan-floor.yml",
        // round-4 fold: string-tag readers, empty-at-runtime tokens, and the
        // round-2/round-3 mechanisms the closure lens measured as unpinned
        "reject-tagged-escaped-uses.yml",
        "reject-tagged-value-escaped-uses.yml",
        "reject-tagged-escaped-quoted-key.yml",
        "reject-quoted-tag-text-runid-key.yml",
        "reject-tagged-uses-key.yml",
        "accept-tagged-key-uses.yml",
        "accept-tagged-value-uses.yml",
        "accept-tagged-structure.yml",
        "reject-tagged-non-string-uses.yml",
        "reject-tagged-null-token.yml",
        "accept-if-negation.yml",
        "reject-run-id-cross-run-empty-token.yml",
        "reject-run-id-cross-run-empty-env-token.yml",
        "reject-run-id-cross-run-unresolved-token.yml",
        "reject-run-id-literal-no-token.yml",
        "reject-block-scalar-with-github-token.yml",
        "accept-step-name-with-ref.yml",
        "accept-job-name-with-ref.yml",
        "accept-mapping-key-ref.yml",
        "reject-uses-token-no-ref.yml",
        "reject-action-ref-value.yml",
        // round-5 fold: the scoped static `env:` chain (R5-MINOR-1), the exact
        // provably-non-empty token forms (R5-MINOR-2), and the string tag on a
        // `needs:` flow collection (R5-NIT-1)
        "accept-tagged-needs-flow.yml",
        "reject-tagged-non-string-needs.yml",
        "accept-token-in-scope-job-env.yml",
        "accept-token-in-scope-workflow-env.yml",
        "reject-token-out-of-scope-job-env.yml",
        "reject-token-out-of-scope-step-env.yml",
        "reject-token-unset-secret.yml",
        "reject-token-compound-secret.yml",
        "reject-run-id-out-of-scope-cross-run-env.yml",
        "reject-run-id-out-of-scope-same-run-env.yml",
        // round-6 fold: YAML-empty `env:` values (R6-BLOCKER-1),
        // case-sensitive `env:` names (R6-BLOCKER-2), step-over-job precedence
        // (R6-MINOR-1), and the transitive link in a chained run-id refusal
        // (R6-NIT-1)
        "reject-token-env-empty-block-scalar-in-scope.yml",
        "reject-token-env-empty-folded-block-scalar-in-scope.yml",
        "reject-token-env-null-tilde-in-scope.yml",
        "reject-token-env-null-literal-in-scope.yml",
        "accept-token-env-nonempty-block-scalar-in-scope.yml",
        "reject-token-env-name-case-mismatch.yml",
        "reject-token-env-name-case-alias.yml",
        "accept-step-env-shadow-over-job-env.yml",
        "reject-step-env-empty-shadow-over-job-env.yml",
        "reject-run-id-chain-out-of-scope-env.yml",
        // round-7 fold: null-tagged `env:` values (R7-BLOCKER-1), bare empty
        // `env:` values that must still shadow (R7-BLOCKER-2), comment-only
        // block-scalar bodies (R7-MAJOR-1), and the case-mismatch run-id
        // wording (R7-NIT-1)
        "reject-token-env-null-tag-in-scope.yml",
        "reject-token-env-verbatim-null-tag-in-scope.yml",
        "reject-step-env-null-tag-shadow-over-job-env.yml",
        "reject-step-env-bare-null-shadow-over-job-env.yml",
        "accept-token-env-comment-block-scalar-in-scope.yml",
        "reject-run-id-case-variant-env.yml",
        // round-8 fold: quoted/escaped null spellings on a null-tagged
        // `env:` value (R8-BLOCKER-1), tagged/anchored block-scalar headers
        // (R8-BLOCKER-1/-2), and the anchor property on a tagged scalar
        // (R8-BLOCKER-2)
        "reject-token-env-quoted-null-tag-in-scope.yml",
        "reject-token-env-quoted-tilde-null-tag-in-scope.yml",
        "reject-token-env-verbatim-quoted-null-tag-in-scope.yml",
        "reject-token-env-quoted-null-tag-shadow-over-job-env.yml",
        "reject-token-env-empty-block-null-tag-in-scope.yml",
        "reject-token-env-escape-null-tag-in-scope.yml",
        "reject-token-env-anchor-null-tag-in-scope.yml",
        "reject-token-env-anchored-quoted-null-tag-in-scope.yml",
        "reject-token-env-string-tag-empty-block-in-scope.yml",
        "reject-token-tagged-anchor-empty-in-scope.yml",
        "accept-token-env-quoted-nonnull-null-tag-in-scope.yml",
        "accept-token-env-null-tag-nonempty-block-in-scope.yml",
        "accept-token-env-anchored-value-null-tag-in-scope.yml",
        "accept-token-anchored-literal-in-scope.yml",
    ]

    // MARK: - P1: the gate and its inputs exist

    @Test
    func testGateScriptFixturesAndManifestExistWithLicenseHeader() throws {
        let root = try Self.repositoryRoot()

        let scriptURL = root.appendingPathComponent(Self.scriptPath)
        #expect(
            FileManager.default.fileExists(atPath: scriptURL.path),
            "the artifact-dependency gate must exist at \(Self.scriptPath) (issue #316)"
        )
        let script = try Self.source(Self.scriptPath)
        #expect(
            script.hasPrefix("#!/usr/bin/env python3\n# SPDX-License-Identifier: MIT"),
            "\(Self.scriptPath) must keep its shebang and its `# SPDX-License-Identifier: MIT` header on the first two lines (scripts/ci/check-license-headers.sh is the first step of the required build job)"
        )

        let fixturesURL = root.appendingPathComponent(Self.fixturesDirectory)
        var isDirectory: ObjCBool = false
        let fixturesExist = FileManager.default.fileExists(
            atPath: fixturesURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        #expect(
            fixturesExist,
            "the fixture directory must exist at \(Self.fixturesDirectory) (issue #316)"
        )
        let manifest = try Self.source(Self.manifestPath)
        #expect(
            manifest.hasPrefix("# SPDX-License-Identifier: MIT"),
            "\(Self.manifestPath) must carry the SPDX header"
        )
        #expect(
            manifest.contains("CASES"),
            "the fixture manifest must expose a CASES list (the selftest's contract)"
        )
    }

    // MARK: - P2: the required build job wires the gate exactly

    @Test
    func testBuildJobRunsTheGateAfterLicenseHeadersWithTheExactStep() throws {
        let source = try Self.workflowSource()
        let stripped = Self.strippingYAMLComments(source)
        let job = try Self.jobBlock(named: "build", in: stripped)

        let steps = Self.stepBlocks(in: job)
        let gateSteps = steps.filter { step in
            step.first?.range(
                of: #"^      - name: Check artifact dependencies\s*$"#,
                options: .regularExpression
            ) != nil
        }
        #expect(
            gateSteps.count == 1,
            "the `build` job must contain exactly one `Check artifact dependencies` step (found \(gateSteps.count)); the gate is the class rule's enforcement point (issue #316)"
        )
        let gateStep = try #require(
            gateSteps.first,
            "the `build` job must contain the `Check artifact dependencies` step (issue #316)"
        )

        // Exact block: normalized whitespace must equal the required commands in
        // order. An appended `|| true`, a dropped `--selftest`, a reordered
        // scan, or a step-level `if:`/`continue-on-error:` all break equality.
        let normalized = gateStep
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            normalized == Self.expectedStepBlock,
            """
            the `Check artifact dependencies` step must run exactly the pinned block (issue #316): \
            python3 preflight, then `--selftest`, then the scan. Got:
            \(normalized)
            """
        )
        #expect(
            !normalized.contains("continue-on-error"),
            "the gate step must not declare `continue-on-error:` — a required check that can fail open is not a gate (issue #316)"
        )
        #expect(
            !normalized.contains(" if:"),
            "the gate step must not declare a step-level `if:` — it must run on every `build` (issue #316)"
        )

        // Job-level guard (lens-2 MINOR 1; round-2 C-NIT-1): assert the
        // `build` job's exact job-level key set after trimming. A job-level
        // `if:` or `continue-on-error:` on the required `build` job makes
        // GitHub report a successful check while the gate never runs, and no
        // step-level assertion can see it. Comparing the whole key set closes
        // every spelling (`if:`, `if :`, `"if":`) at once: any unexpected
        // key reds until this pin is re-derived.
        let jobLevelKeyLines = job.lines.filter { line in
            line.range(of: #"^    \S"#, options: .regularExpression) != nil
        }
        let jobLevelKeys = Set(jobLevelKeyLines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
            return String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        })
        #expect(
            jobLevelKeys == Self.expectedBuildJobKeys,
            """
            the `build` job must declare exactly the pinned job-level keys (issue #316): \
            \(Self.expectedBuildJobKeys.sorted()) — found \(jobLevelKeys.sorted()). A job-level \
            `if:` or `continue-on-error:` (in any spelling) can skip the required job and report \
            success, so any unexpected key must red this pin.
            """
        )
        #expect(
            job.lines.first?.trimmingCharacters(in: .whitespaces) == "build:",
            "the `build` job key line must be exactly `  build:` — an inline job-level key would carry a job-level condition the step pins cannot see (issue #316)"
        )

        // Ordering inside the required `build` job: license gate → artifact
        // gate → build prep → xcodebuild. A move that skipped the gate on the
        // normal path would otherwise be invisible.
        let jobText = job.text
        let licenseRange = jobText.range(of: "Check license headers")
        let gateRange = jobText.range(of: "Check artifact dependencies")
        let prepareRange = jobText.range(of: "Prepare Xcode build (mtimes, caches, Metal toolchain)")
        let buildRange = jobText.range(of: "xcodebuild build-for-testing")
        #expect(licenseRange != nil, "the `build` job must keep the `Check license headers` step (issue #316 placement precedent)")
        #expect(gateRange != nil, "the `build` job must contain the artifact-dependency gate step (issue #316)")
        #expect(prepareRange != nil, "the `build` job must keep the `Prepare Xcode build` step")
        #expect(buildRange != nil, "the `build` job must keep `xcodebuild build-for-testing`")
        if let licenseRange, let gateRange, let prepareRange, let buildRange {
            #expect(
                licenseRange.lowerBound < gateRange.lowerBound,
                "the artifact-dependency gate must run immediately after `Check license headers` (issue #316)"
            )
            #expect(
                gateRange.lowerBound < prepareRange.lowerBound && gateRange.lowerBound < buildRange.lowerBound,
                "the artifact-dependency gate must run before `Prepare Xcode build`/`xcodebuild` (issue #316): a violation must fail in ~1s, not after a 15m build"
            )
        }

        // Positive controls: the pin resolved the real job, not an empty slice.
        #expect(
            jobText.contains("Build for iOS Simulator (build-for-testing)"),
            "the pin resolved the real `build` job, not an empty or shifted slice"
        )
    }

    // MARK: - P3: the shape guard

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

    // MARK: - P4: the fixture inventory

    @Test
    func testFixtureInventoryCoversTheRequiredCases() throws {
        let root = try Self.repositoryRoot()
        let manifest = try Self.source(Self.manifestPath)
        let script = try Self.source(Self.scriptPath)

        for fixture in Self.requiredFixtures {
            let url = root.appendingPathComponent(Self.fixturesDirectory).appendingPathComponent(fixture)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "required fixture missing: \(Self.fixturesDirectory)/\(fixture) (issue #316) — every measured hole needs a fixture, not a comment"
            )
            #expect(
                manifest.contains(fixture),
                "the manifest must reference \(fixture): an unreferenced fixture is dead weight and a deleted case would otherwise be invisible (issue #316)"
            )
        }

        let onDisk = (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(Self.fixturesDirectory).path
        )) ?? []
        let fixtureFiles = onDisk.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        #expect(
            fixtureFiles.count >= Self.requiredFixtures.count,
            "the fixture directory holds \(fixtureFiles.count) YAML file(s), fewer than the \(Self.requiredFixtures.count) required — a deleted fixture file must red this pin (issue #316)"
        )

        // The script must reference the manifest, and carry the stated
        // manifest-length constant that `--selftest` enforces.
        #expect(
            script.contains("manifest.py") && script.contains("fixtures") && script.contains("artifact-dependency"),
            "\(Self.scriptPath) must reference the fixture manifest by its fixtures/artifact-dependency path (issue #316)"
        )
        #expect(
            script.contains("EXPECTED_MANIFEST_CASES = \(Self.expectedManifestCases)"),
            "\(Self.scriptPath) must state EXPECTED_MANIFEST_CASES = \(Self.expectedManifestCases) — a stale constant would let a deleted manifest case pass `--selftest` (issue #316, lens-2 NIT 1)"
        )
        #expect(
            script.contains("MIN_SCANNED_WORKFLOW_FILES = \(Self.expectedWorkflowFloor)"),
            "\(Self.scriptPath) must state MIN_SCANNED_WORKFLOW_FILES = \(Self.expectedWorkflowFloor) — a stale floor would let a truncated tree pass (issue #316, lens-2 NIT 1)"
        )
        let manifestCaseCount = manifest.components(separatedBy: "\"id\"").count - 1
        #expect(
            manifestCaseCount == Self.expectedManifestCases,
            "the manifest must hold \(Self.expectedManifestCases) case(s) (counted \(manifestCaseCount)) — a stale constant reds this pin, not only the build-time `--selftest` (issue #316)"
        )
    }

    // MARK: - P5: the diagnostic contract

    @Test
    func testGateDiagnosticContractIsPresentAsCode() throws {
        let script = Self.strippingPythonComments(try Self.source(Self.scriptPath))

        // The rule diagnostic (plan §4.4): the manifest asserts these exact
        // strings, so they must exist as executable text, not prose.
        let requiredDiagnostics = [
            "downloads artifact",
            "but no needs: path reaches its producer",
            "no job in this workflow uploads that literal name",
            "artifacts are run-scoped; use `run-id:` for a cross-run handoff",
            "producer is in",
            "unterminated quoted scalar",
            "unconsumed line",
            "tab in indentation",
            "duplicate mapping key",
            "duplicate job",
            "merge key '<<'",
            "anchor or alias",
            "download step has no 'name:'",
            "is not a literal",
            "'pattern:' on an artifact download",
            "'artifact-ids:' on an artifact download",
            "empty 'run-id:'",
            "unrecognized 'run-id:'",
            "uploaded more than once",
            "no top-level 'jobs:' mapping",
            "'jobs:' is empty",
            "reconciliation failed",
            "scan floor:",
            "unsupported backslash escape",
            "block scalar header",
            "before its own upload step",
            "move the upload step earlier",
            "resolves through a static assignment in this file",
            "`needs: {producer}` to the `{job.name}` job",
            "YAML tag",
            "only the string tag",
            "cannot be proven non-empty at runtime",
        ]
        for diagnostic in requiredDiagnostics {
            #expect(
                script.contains(diagnostic),
                "the gate must keep the diagnostic fragment `\(diagnostic)` as code: the fixture manifest asserts exact diagnostic lines, so a reworded refusal is a broken contract (issue #316)"
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
        try source(workflowPath)
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
    /// instead of silently merging into its neighbour.
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

    /// The job's bare name. Splits at the first colon so an anchored key still
    /// yields the name; the canonical-shape guard rejects the anchor itself.
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
    /// escapes) scalars are copied verbatim.
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

    /// Strips Python comments line-by-line so the P5 diagnostic fragments are
    /// asserted against code only. The gate's strings contain no `#`, and a
    /// `#` inside a string literal would only make this MORE conservative.
    private static func strippingPythonComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let hash = line.firstIndex(of: "#") else { return line }
                return String(line[..<hash])
            }
            .joined(separator: "\n")
    }
}
