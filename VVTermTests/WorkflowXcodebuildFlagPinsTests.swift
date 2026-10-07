// SPDX-License-Identifier: MIT
//
//  WorkflowXcodebuildFlagPinsTests.swift
//  VVTermTests
//
//  Source pins for the CI xcodebuild invocations and the #249 + #396
//  extractions.
//
//  Pin 1 (issue #319): the `debug-test` job's diagnostic invocation passed
//  `-collect-test-diagnostics always`, which is not a value xcodebuild
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
//  `-collect-test-diagnostics` value in every workflow or CI script is one
//  xcodebuild accepts", which is the invariant the toolchain enforces and the
//  one the job's author could not see.
//
//  Pin 2 (issue #249): the `Run UI tests (shard …)` step was an 8,849-escaped-
//  char `run: |` block scalar containing `${{ matrix.shard.* }}` interpolations,
//  so GitHub compiled the whole scalar into one expression and applies the
//  21,000-character limit to it; push `2849c5a8` produced a **0-job run**
//  ("failed to parse workflow: … Exceeded max expression length 21000"). The
//  shard logic moved to `scripts/ci/run-ui-tests.sh`; the step must stay a
//  small delegating `run: |` scalar, and the script must keep the load-bearing
//  xcodebuild invocation, its exit plumbing and the xctestrun plist injection
//  (the silent-break surface: an indented heredoc body raises IndentationError,
//  `set +e` swallows it, and 13 loopback-fixture tests XCTSkip green).
//
//  Pin 3 (issue #396): the ghostty probe's bump-PR step (`Commit artifacts,
//  push bump branch, create or reuse bump PR`, id `bump-pr`) was a 15,077-
//  escaped-char `run: |` scalar (14,785 chars + 292 newlines = 71.8% of the
//  21,000 limit) carrying five `${{ }}` occurrences. The probe is schedule/
//  dispatch-only, so a parse rejection has no push run to 0-job: it stops
//  the weekly bump silently, strictly worse than the recorded #249 signature.
//  The step body moved to `scripts/ci/ghostty-bump-pr.sh` (the two
//  `${{ github.* }}` assignments normalized to `$1`/`$2`; everything from
//  `SHA7="${RESOLVED_SHA:0:7}"` to EOF byte-identical to the parsed scalar);
//  the step must stay <= 1,200 escaped (measured 279) and keep its
//  failing-step marker first plus the `inputs.create_bump_pr` diagnostic (the
//  documented Trap-3 dispatch-mishap diagnostic). A repo-wide budget guard
//  caps every `${{`-bearing `run: |` scalar at 10,000 escaped.
//
//  FORMATTING HEURISTIC, NOT A PROOF: these pins parse the workflow and script
//  as text. A real YAML parse would be sounder, but a YAML toolchain (`yq`/`jq`)
//  is not guaranteed on the `xcode-27` runner (ios-adhoc-pr.yml installs jq
//  defensively) and a required job must not take a network dependency for a
//  lint. Comments are stripped YAML-style before the scan, so a
//  commented-out `# -collect-test-diagnostics always` is prose, not a flag —
//  and so the explanatory comments this pin ships with (which quote the
//  toolchain's error text) do not red it. Defeat list, stated honestly
//  (hardened in fold round 1, impl lens 2):
//  a value assembled from a shell variable (e.g.
//  `-collect-test-diagnostics "$DIAG"`) reds the pin deliberately rather than
//  passing — the pin requires a literal accepted value, so an indirect form
//  must be re-affirmed here; a double-dash spelling
//  (`--collect-test-diagnostics`) is also seen by the unanchored scan and
//  reds with its following token as the value (fail-closed), so the earlier
//  "is not seen" claim is dropped; a flag that appears only in a comment does
//  not count — the #249 assertions are comment-stripped and
//  invocation-scoped, and the invocation region is comment-cut again line by
//  line so a stuck YAML stripper cannot satisfy them; a duplicated
//  load-bearing flag reds (each pinned flag must occur exactly once with its
//  pinned value, because xcodebuild option parsing is last-wins and a second
//  `-test-timeouts-enabled NO` / `-parallel-testing-enabled YES` would
//  silently override the pin); the delegation matrix arguments are checked
//  inside the call's own comment-stripped continuation, and the flags are
//  cut at the pipeline's first `|`, so text in a comment or after the `tee`
//  operand cannot satisfy them; a comment-only script reference, a decoy
//  second step, an inline/folded scalar (`run: >-`, `run: |2`, `run: …`), a
//  hard-coded indentation or a second step-level `run:` key all red the shape
//  guard rather than pass. #396 adds: the moved script's region parity is a
//  one-off pre-merge evidence artifact (the byte-diff in the PR), not re-run
//  by CI, and the script's first real execution is deferred — the probe is
//  mid-rebase (#376); the `probe-passed` marker pin is a textual count of 3
//  writes paired with the alarm step's textual read, not a control-flow
//  proof; the repo-wide budget guard scans only `run: |` block scalars
//  (`env:`/`if:`/`with:` scalars are separate expressions; the single inline
//  expression-bearing `run:` today — `ios-adhoc-pr.yml`, 104 chars — is
//  unreadable by `dedentedRunBlockScalar` and so outside the scan, recorded
//  under the bound by hand), and the recorded expression-length note's own
//  reading of whether non-expression `run` scalars are length-checked is
//  unresolved — 0 such scalars exceed 10,000 today, so the guard's verdict
//  is unaffected. Residual bounds: the heredoc backstop is textual —
//  it requires exactly one `<<'PY'` opener (unconditional: an unrelated second
//  `PY` heredoc in this script reds fail-closed and requires re-deriving the
//  pin), each opener's first non-blank body line at column 0 and exactly one
//  column-0 `PY` terminator after it — but it does not `ast.parse` the body or
//  prove the injected marker text is reachable code; the `run:`/step scanner
//  is a text heuristic that fails closed with a re-derive message when it
//  cannot prove exactly one step-level key; the pipeline cut is quote-unaware,
//  so a `|` inside a quoted argument reds every flag assertion (fail-closed
//  false red); and control flow is not modelled, so a pre-invocation `exit`
//  with a computed status, an arithmetic spelling (`exit +0`), or a
//  zero-looking `exit` inside a data-heredoc body is invisible to the
//  anchored re-exit assertion (a bare `exit` with a literal zero argument in
//  the common spellings — `0`, `00`, `"0"`, `'0'`, `0;` — is rejected
//  outright, because it would end the shard green with zero tests run; a
//  zero-looking line inside a heredoc body false-reds, fail-closed). The
//  #396 heredoc backstop is textual: exactly one `<<JSON` opener (an
//  unrelated second one reds fail-closed), its first non-blank body line at
//  column 0 and exactly one column-0 `JSON` terminator after it; the budget
//  guard's population floor is 24, the readable expression-bearing `run: |`
//  scalars (the plan's 25 counted the inline scalar the scanner cannot read).
//
//  The script corpus reuses the same YAML-comment stripper, and the two
//  languages' quoting rules diverge: the stripper does not model bash
//  heredocs, backticks or apostrophes. Measured at #249, in
//  `scripts/ci/check-isolated-deinit-census.sh` the apostrophe in `build's`
//  inside a `cat <<'EOF'` heredoc body (`:245`) is read as an unterminated
//  single-quoted scalar, so everything after it is copied verbatim — a
//  commented-out flag probe there would not be blanked. The failure mode is a
//  **visible false red**, never a false pass: the invocation region is
//  comment-cut locally, so the measured stuck-stripper evasion (a
//  comment-only timeout flag — ev-10) reds the flag assertion as well as the
//  corpus scan; and the `run-ui-tests.sh` scan was measured to see exactly
//  one `-collect-test-diagnostics never`, at its `xcodebuild` line.
//
//  Counterfactual hook: `VVTERM_PINS_SOURCE_ROOT` points the scans at a
//  mutated tree (the measured-working form is
//  `TEST_RUNNER_VVTERM_PINS_SOURCE_ROOT=<tree>` exported into xcodebuild's own
//  environment). A two-file tree (`.github/workflows/vvterm-pr-ci.yml` +
//  `scripts/ci/run-ui-tests.sh`) covers the #249 pins; the #396 pins need a
//  copy of the full `.github/workflows/` + `scripts/ci/` trees — the budget
//  guard enumerates every workflow and the corpus controls read
//  vvterm-pr-ci.yml/run-ui-tests.sh. Never set in CI.
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

    /// No workflow or CI script may pass a `-collect-test-diagnostics` value
    /// xcodebuild rejects — the failure mode is a step that dies in ~1 s
    /// without running a test, which reads like a test problem rather than a
    /// usage error.
    @Test
    func testEveryCollectTestDiagnosticsValueIsAcceptedByXcodebuild() throws {
        let occurrences = try Self.collectTestDiagnosticsOccurrences()

        #expect(
            !occurrences.isEmpty,
            "no `-collect-test-diagnostics` flag was found in any workflow or CI script — re-derive this pin (issue #319)"
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

        // File-scoped control (#249): the UI-shard invocation moved into
        // scripts/ci/run-ui-tests.sh, so the corpus extension must actually
        // reach it. The value controls above cannot see the difference —
        // vvterm-pr-ci.yml:471 and repro-zmx.yml:205 still carry `never`.
        #expect(
            occurrences.contains { $0.file == "scripts/ci/run-ui-tests.sh" && $0.value == "never" },
            "the scan must reach scripts/ci/run-ui-tests.sh and find its `-collect-test-diagnostics never` (issue #249) — re-derive this pin"
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

    /// The #249 shape pin: the `Run UI tests` step must stay a small
    /// delegating `run: |` block scalar, and `scripts/ci/run-ui-tests.sh` must
    /// keep the load-bearing invocation, exit plumbing and plist injection.
    /// The extraction has two opposite failure modes, and both are silent:
    /// the step re-growing past the GitHub expression budget (0-job parse
    /// failure), or the script losing a flag / the exit status / the plist
    /// injection while every shard still exits green.
    @Test
    func testTheUITestStepDelegatesToTheScriptAndStaysSmall() throws {
        let workflowPath = ".github/workflows/vvterm-pr-ci.yml"
        let scriptPath = "scripts/ci/run-ui-tests.sh"
        let workflow = try Self.workflowSource(workflowPath)
        let script = try Self.workflowSource(scriptPath)

        // Exactly one `Run UI tests (` step, and it is a `run: |` block scalar.
        let nameLines = workflow.components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains("- name: Run UI tests (") }
        #expect(
            nameLines.count == 1,
            "expected exactly one `Run UI tests (` step in \(workflowPath), found \(nameLines.count) — re-derive this pin (issue #249)"
        )
        let stepLine = try #require(
            nameLines.first?.offset,
            "the `Run UI tests (` step is missing from \(workflowPath) — re-derive this pin (issue #249)"
        )
        let body = try #require(
            Self.dedentedRunBlockScalar(in: workflow, stepLineIndex: stepLine),
            "the `Run UI tests` step must keep exactly one step-level `run:` key and stay a `run: |` literal block scalar (not an inline/folded scalar or a duplicate/decoy `run:` key) so #249's size and delegation pins read the body GitHub actually runs — re-derive this pin"
        )

        // The escaped-size recipe from the recorded debugging note: dedent the
        // scalar, count chars + newlines (comments included). The limit is
        // 21,000; the #249 bound is 1,200, far below every candidate metric.
        let newlineCount = body.components(separatedBy: "\n").count - 1
        let escapedSize = body.count + newlineCount
        #expect(
            escapedSize <= 1_200,
            "the `Run UI tests` step body is \(escapedSize) escaped chars (dedented scalar chars \(body.count) + \(newlineCount) newlines); #249 caps it at 1,200 because the whole scalar is one GitHub expression and >21,000 makes the push produce a 0-job run (the pre-extraction scalar was 8,849). Move logic into \(scriptPath) — re-derive with the pyyaml recipe"
        )

        // Delegation: a real (non-comment) call with all three matrix values
        // inside the call's own argument list. Impl lens 2 (ev-6) passed the
        // old body-wide contains() with the arguments only in a trailing
        // comment, so scope them to the call's comment-stripped continuation;
        // closure lens fold-1 finding 1: each call line is comment-cut too, so
        // an argument parked in a trailing comment on the call line cannot
        // satisfy the assertion.
        let codeLines = body.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        #expect(
            codeLines.first?.contains("bash scripts/ci/run-ui-tests.sh") == true,
            "the `Run UI tests` step must delegate with `bash scripts/ci/run-ui-tests.sh`: a comment-only reference runs nothing (issue #249)"
        )
        var callLines: [String] = []
        if !codeLines.isEmpty {
            callLines.append(codeLines[0])
            var callCursor = 0
            while callCursor + 1 < codeLines.count, codeLines[callCursor].hasSuffix("\\") {
                callCursor += 1
                callLines.append(codeLines[callCursor])
            }
        }
        let callText = callLines.map(Self.cuttingLineComment).joined(separator: "\n")
        for argument in [
            "${{ matrix.shard.name }}",
            "${{ matrix.shard.needs-fixture }}",
            "${{ matrix.shard.only-testing }}",
        ] {
            #expect(
                callText.contains("\"\(argument)\""),
                "the `Run UI tests` step must pass \(argument) to \(scriptPath) inside the delegation call's own argument list (not in a comment or outside the call) — re-derive this pin (issue #249)"
            )
        }

        // The script carries the invocation. Comment-strip first: the moved
        // rationale comments quote `-collect-test-diagnostics never` and
        // `-test-timeouts-enabled YES` verbatim, so an unstripped contains()
        // would pass even with the real flags gone.
        let strippedScript = Self.strippingYAMLComments(script)
        let scriptLines = strippedScript.components(separatedBy: "\n")
        let invocationLines = scriptLines.enumerated().filter {
            $0.element.contains("xcodebuild test-without-building")
        }
        #expect(
            invocationLines.count == 1,
            "\(scriptPath) must contain exactly one `xcodebuild test-without-building` invocation, found \(invocationLines.count) — re-derive this pin (issue #249)"
        )
        let invocationLine = try #require(
            invocationLines.first?.offset,
            "\(scriptPath) no longer contains `xcodebuild test-without-building` — re-derive this pin (issue #249)"
        )

        // The invocation's continuation block: the invocation line and every
        // following line while the previous one ends with `\`.
        var continuation: [String] = []
        var cursor = invocationLine
        while cursor < scriptLines.count {
            let line = scriptLines[cursor]
            continuation.append(line)
            if !line.hasSuffix("\\") { break }
            cursor += 1
        }
        // Impl lens 2 (fold round 1): the invocation region must hold only
        // real xcodebuild arguments. Cut whole-line comments locally (a stuck
        // YAML stripper can leave them in place — ev-10) and everything from
        // the pipeline's first `|` onward (ev-7 moved a flag onto the `tee`
        // line), then tokenize what remains so each flag is bound to a unique
        // occurrence and its pinned value — xcodebuild option parsing is
        // last-wins, so a duplicate could silently override the pin (ev-11).
        let invocationCodeLines = continuation.map(Self.cuttingLineComment)
        let invocationCode = invocationCodeLines.joined(separator: "\n")
        let pipeIndex = invocationCode.firstIndex(of: "|")
        let argumentRegion = pipeIndex.map { String(invocationCode[..<$0]) } ?? invocationCode
        let flagTokens = argumentRegion
            .replacingOccurrences(of: "\\", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        func expectFlag(_ flag: String, value: String) {
            let occurrences = flagTokens.indices.filter { flagTokens[$0] == flag }
            #expect(
                occurrences.count == 1,
                "the xcodebuild invocation in \(scriptPath) must pass `\(flag) \(value)` exactly once before the `|` pipeline, found \(occurrences.count) `\(flag)` token(s) — xcodebuild option parsing is last-wins, so a duplicate can silently override the pinned value — re-derive this pin (issue #249)"
            )
            if let first = occurrences.first {
                let nextToken = first + 1 < flagTokens.count ? flagTokens[first + 1] : "<end of invocation>"
                #expect(
                    nextToken == value,
                    "the `\(flag)` token in the xcodebuild invocation of \(scriptPath) is followed by `\(nextToken)`, expected `\(value)` — re-derive this pin (issue #249)"
                )
            }
        }

        expectFlag("-collect-test-diagnostics", value: "never")
        expectFlag("-test-timeouts-enabled", value: "YES")
        expectFlag("-default-test-execution-time-allowance", value: "300")
        expectFlag("-maximum-test-execution-time-allowance", value: "300")
        expectFlag("-parallel-testing-enabled", value: "NO")

        let codeSigningOccurrences = flagTokens.filter { $0 == "CODE_SIGNING_ALLOWED=NO" }
        #expect(
            codeSigningOccurrences.count == 1,
            "the xcodebuild invocation in \(scriptPath) must pass `CODE_SIGNING_ALLOWED=NO` exactly once before the `|` pipeline, found \(codeSigningOccurrences.count) — re-derive this pin (issue #249)"
        )
        #expect(
            invocationCode.contains(#"| tee "$RUNNER_TEMP/test.log""#),
            #"the xcodebuild invocation in \#(scriptPath) must pipe through `| tee "$RUNNER_TEMP/test.log"` so a failed shard still uploads its log — re-derive this pin (issue #249)"#
        )

        // `PIPESTATUS[0]` must be captured by the immediately next statement
        // (comments allowed) in the exact `XC_EXIT=${PIPESTATUS[0]}`
        // assignment shape: any intervening command clobbers the status, and a
        // bare reference or a different assignment leaves the captured status
        // unset, so a red shard could exit green.
        let afterPipeline = scriptLines[(cursor + 1)...].first {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }?.trimmingCharacters(in: .whitespaces) ?? ""
        #expect(
            afterPipeline.range(of: #"^XC_EXIT=\$\{PIPESTATUS\[0\]\}$"#, options: .regularExpression) != nil,
            "the statement immediately after the xcodebuild pipeline in \(scriptPath) must be exactly `XC_EXIT=${PIPESTATUS[0]}` (found `\(afterPipeline)`) — an intervening command clobbers the status and a bare reference leaves the captured status unset — re-derive this pin (issue #249)"
        )

        // The re-exit must be an anchored `exit $XC_EXIT` / `exit "$XC_EXIT"`
        // statement; a file-wide contains could be satisfied by `exit 0` or an
        // echoed token elsewhere.
        let exitLines = scriptLines.enumerated().filter {
            $0.element.trimmingCharacters(in: .whitespaces)
                .range(of: #"^exit\s+"?\$XC_EXIT"?$"#, options: .regularExpression) != nil
        }
        #expect(
            exitLines.count == 1,
            "\(scriptPath) must re-exit with xcodebuild's captured status exactly once (`exit $XC_EXIT` or `exit \"$XC_EXIT\"`), found \(exitLines.count) matching statement(s) — re-derive this pin (issue #249)"
        )

        // Closure lens (fold round 1, finding 2; re-lens fold-2 finding 1): a
        // pre-invocation `exit 0` ends the shard green with zero tests run,
        // and the anchored re-exit assertion above cannot see it — this is a
        // text pin with no control-flow model. Reject a bare `exit` whose
        // argument is a literal zero in the common bash-zero spellings
        // (`exit 0`, `exit 00`, `exit "0"`, `exit '0'`, `exit 0;`); a computed
        // pre-invocation exit, an arithmetic spelling (`exit +0`), and a
        // zero-looking `exit` inside a data-heredoc body remain named
        // residual bounds in the header.
        let zeroExitLines = scriptLines.enumerated().filter {
            $0.element.trimmingCharacters(in: .whitespaces)
                .range(of: #"^exit\s+['"]?0+['"]?\s*;?\s*$"#, options: .regularExpression) != nil
        }
        #expect(
            zeroExitLines.isEmpty,
            "\(scriptPath) must not contain a bare zero exit in a common spelling (found at line(s) \(zeroExitLines.map { String($0.offset + 1) }.joined(separator: ", "))): an early zero exit ends the shard green without running tests, and the anchored re-exit assertion cannot see it — re-derive this pin (issue #249)"
        )

        // The plist injection is the extraction's silent-break surface: an
        // indented heredoc body raises IndentationError, `set +e` swallows it,
        // and xcodebuild runs without SCREENSHOT_DIR / keepAlways / the fixture
        // env — the 13 loopback-fixture tests XCTSkip green and screenshots drop.
        #expect(
            strippedScript.contains(#"env["SCREENSHOT_DIR"] = screenshot_dir"#),
            "\(scriptPath) must keep the xctestrun plist injection (`SCREENSHOT_DIR` + `keepAlways` + the fixture env): without it the 13 loopback-fixture tests XCTSkip green and screenshots drop — re-derive this pin (issue #249)"
        )
        #expect(
            strippedScript.contains("keepAlways"),
            "\(scriptPath) must keep `keepAlways` attachment lifetimes or passing tests drop their screenshots — re-derive this pin (issue #249)"
        )

        // Impl lens 2 (fold round 1): the old backstop checked only the first
        // `<<'PY'` opener's immediate next line, so a decoy opener (ev-1) or a
        // blank first body line (ev-2) left the real, indented heredoc
        // unchecked. Check every opener instead, and require exactly one
        // opener and exactly one column-0 `PY` terminator, so a decoy cannot
        // shadow the real heredoc; each mismatch records its own issue with
        // the opener's line.
        let heredocLines = strippedScript.components(separatedBy: "\n")
        let pyOpeners = heredocLines.enumerated().filter { $0.element.contains("<<'PY'") }
        let pyTerminators = heredocLines.enumerated().filter { $0.element == "PY" }
        if pyOpeners.isEmpty {
            Issue.record(
                "\(scriptPath) no longer contains the `<<'PY'` plist-injection heredoc — re-derive this pin (issue #249)"
            )
        } else if pyOpeners.count > 1 {
            Issue.record(
                "\(scriptPath) must contain exactly one `<<'PY'` plist-injection heredoc, found \(pyOpeners.count) openers at lines \(pyOpeners.map { String($0.offset + 1) }.joined(separator: ", ")) — a decoy opener can shadow the real heredoc — re-derive this pin (issue #249)"
            )
        }
        if pyTerminators.count != 1 {
            Issue.record(
                "\(scriptPath) must contain exactly one column-0 `PY` heredoc terminator, found \(pyTerminators.count) at lines \(pyTerminators.map { String($0.offset + 1) }.joined(separator: ", ")) — an early decoy terminator silently truncates the plist injection — re-derive this pin (issue #249)"
            )
        }
        for (openerIndex, _) in pyOpeners {
            let bodyStartIndex = heredocLines[(openerIndex + 1)...].firstIndex {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard let bodyStartIndex else {
                Issue.record(
                    "the `<<'PY'` heredoc opened at line \(openerIndex + 1) of \(scriptPath) has no body lines — re-derive this pin (issue #249)"
                )
                continue
            }
            let firstBodyLine = heredocLines[bodyStartIndex]
            if firstBodyLine.hasPrefix(" ") || firstBodyLine.hasPrefix("\t") {
                Issue.record(
                    "the first non-blank line of the `<<'PY'` heredoc opened at line \(openerIndex + 1) of \(scriptPath) is indented (`\(firstBodyLine.prefix(40))`): an indented heredoc body raises IndentationError and `set +e` lets the script continue with the plist injection silently skipped — re-derive this pin (issue #249)"
                )
            }
            if !heredocLines[(openerIndex + 1)...].contains("PY") {
                Issue.record(
                    "the `<<'PY'` heredoc opened at line \(openerIndex + 1) of \(scriptPath) has no column-0 `PY` terminator after it — re-derive this pin (issue #249)"
                )
            }
        }
    }

    /// The #396 shape pin: the ghostty probe's bump-PR step must stay a small
    /// delegating `run: |` block scalar, and `scripts/ci/ghostty-bump-pr.sh`
    /// must keep the bump logic that changes behavior silently if lost. The
    /// step is schedule/dispatch-only, so its failure mode is not the recorded
    /// 0-job push run — it is the weekly bump silently going dark; this pin is
    /// the structural guard and the PR evidence carries the region-scoped
    /// byte-parity diff of the move.
    @Test
    func testTheGhosttyProbeBumpStepDelegatesToTheScriptAndStaysSmall() throws {
        let workflowPath = ".github/workflows/ghostty-upstream-probe.yml"
        let scriptPath = "scripts/ci/ghostty-bump-pr.sh"
        let stepName = "Commit artifacts, push bump branch, create or reuse bump PR"
        let workflow = try Self.workflowSource(workflowPath)
        let script = try Self.workflowSource(scriptPath)

        // Exactly one step with the pinned name, and it is a `run: |` literal
        // block scalar. Fail closed with a re-derive message otherwise.
        let nameLines = workflow.components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains("- name: \(stepName)") }
        #expect(
            nameLines.count == 1,
            "expected exactly one `\(stepName)` step in \(workflowPath), found \(nameLines.count) — re-derive this pin (issue #396)"
        )
        let stepLine = try #require(
            nameLines.first?.offset,
            "the `\(stepName)` step is missing from \(workflowPath) — re-derive this pin (issue #396)"
        )
        let body = try #require(
            Self.dedentedRunBlockScalar(in: workflow, stepLineIndex: stepLine),
            "the `\(stepName)` step must keep exactly one step-level `run:` key and stay a `run: |` literal block scalar (not an inline/folded scalar or a duplicate/decoy `run:` key) so #396's size and delegation pins read the body GitHub actually runs — re-derive this pin"
        )

        // The escaped-size recipe: dedent the scalar, count chars + newlines.
        // The extraction took this step from 15,077/21,000 (71.8%) to a
        // delegating call; the #396 bound is the #249 bound (1,200).
        let newlineCount = body.components(separatedBy: "\n").count - 1
        let escapedSize = body.count + newlineCount
        #expect(
            escapedSize <= 1_200,
            "the `\(stepName)` step body is \(escapedSize) escaped chars (dedented scalar chars \(body.count) + \(newlineCount) newlines); #396 caps it at 1,200 because the probe is schedule/dispatch-only and an over-budget scalar stops the weekly bump silently (the pre-extraction scalar was 15,077). Move logic into \(scriptPath) — re-derive with the pyyaml recipe"
        )

        // Shape: the failing-step marker must stay the FIRST code line (if the
        // script cannot start, the alarm must still name this step), and the
        // Trap-3 `inputs.create_bump_pr` diagnostic must stay visible.
        let codeLines = body.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        #expect(
            codeLines.first?.trimmingCharacters(in: .whitespaces)
                == #"echo "create-bump-pr" > "$RUNNER_TEMP/ghostty-probe-step""#,
            "the `\(stepName)` step must keep the failing-step marker as its first code line: the alarm step names that marker even when the script cannot start — re-derive this pin (issue #396)"
        )
        #expect(
            body.contains(#"echo "inputs.create_bump_pr='${{ inputs.create_bump_pr }}'""#),
            "the `\(stepName)` step must keep the `inputs.create_bump_pr` diagnostic (the documented Trap-3 dispatch-mishap diagnostic) — re-derive this pin (issue #396)"
        )

        // Delegation, located by content (the marker is deliberately first, so
        // never walk from codeLines[0]): exactly one comment-cut line starts
        // the call, and both arguments sit inside its own continuation.
        let delegationLines = codeLines.enumerated().filter {
            Self.cuttingLineComment($0.element).trimmingCharacters(in: .whitespaces)
                .hasPrefix("bash scripts/ci/ghostty-bump-pr.sh")
        }
        #expect(
            delegationLines.count == 1,
            "the `\(stepName)` step must delegate with exactly one `bash \(scriptPath)` call: a comment-only reference runs nothing and a decoy second call hides which script runs — re-derive this pin (issue #396)"
        )
        var callLines: [String] = []
        if let callStart = delegationLines.first?.offset {
            callLines.append(codeLines[callStart])
            var callCursor = callStart
            while callCursor + 1 < codeLines.count, codeLines[callCursor].hasSuffix("\\") {
                callCursor += 1
                callLines.append(codeLines[callCursor])
            }
        }
        let callText = callLines.map(Self.cuttingLineComment).joined(separator: "\n")
        #expect(
            callText.contains(#""${{ github.repository }}""#),
            "the `\(stepName)` step must pass `github.repository` to \(scriptPath) inside the delegation call's own argument list (not in a comment or outside the call) — re-derive this pin (issue #396)"
        )
        #expect(
            callText.contains(#"${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"#),
            "the `\(stepName)` step must pass the probe run URL to \(scriptPath) inside the delegation call's own argument list — re-derive this pin (issue #396)"
        )

        // Invariant pair: the alarm step must still read the marker the script
        // writes (the script's 3 write sites are asserted below).
        let strippedWorkflow = Self.strippingYAMLComments(workflow)
        #expect(
            strippedWorkflow.contains(#"[[ -f "$RUNNER_TEMP/ghostty-probe-ok" ]]"#),
            "the alarm step must still read `$RUNNER_TEMP/ghostty-probe-ok`: without it the script's post-PR markers are dead and pre-PR failures file false alarms — re-derive this pin (issue #396)"
        )

        // Script load-bearing lines, in the comment-stripped script,
        // occurrence bound: a duplicated or dropped statement is how a bad
        // edit hides.
        let strippedScript = Self.strippingYAMLComments(script)
        let scriptLines = strippedScript.components(separatedBy: "\n")

        func expectExactlyOneLine(containing needle: String, _ reason: String) {
            let matches = scriptLines.enumerated().filter { $0.element.contains(needle) }
            #expect(
                matches.count == 1,
                "\(scriptPath) must contain exactly one line containing `\(needle)`, found \(matches.count) at line(s) \(matches.map { String($0.offset + 1) }.joined(separator: ", ")) — \(reason) — re-derive this pin (issue #396)"
            )
        }

        // Verified commit via the Git API: the only commit shape that
        // satisfies required_signatures for an app-created commit.
        expectExactlyOneLine(
            containing: #"gh api -X POST "repos/${REPO}/git/commits""#,
            "the API-created (web-flow verified) commit is the only commit shape that satisfies required_signatures; a local `git commit` leaves the PR mergeability-BLOCKED"
        )
        expectExactlyOneLine(
            containing: #""tree": "${TREE}", "parents": ["${PARENT}"]"#,
            "the API commit must carry the written tree and the selected parent"
        )
        expectExactlyOneLine(
            containing: #"--jq '.commit.verification.verified'"#,
            "the verification read is half of the required_signatures gate"
        )
        expectExactlyOneLine(
            containing: #"[[ "$VERIFIED" != "true" ]]"#,
            "an unverified API commit must abort instead of pushing a permanently blocked bump"
        )

        // Scratch blob-upload vehicle: the push must go to a TAG (branch
        // pushes of the unsigned scratch commit are rejected by
        // required_signatures — alarm #173).
        expectExactlyOneLine(
            containing: #"git push -q origin "+${TMP_COMMIT}:refs/tags/${SCRATCH}""#,
            "the scratch upload must be a tag push: a branch push of the unsigned scratch commit is rejected by required_signatures (alarm #173)"
        )
        #expect(
            scriptLines.contains { $0.contains(#"gh api -X DELETE "repos/${REPO}/git/refs/tags/${SCRATCH}""#) },
            "\(scriptPath) must keep the scratch-tag cleanup — re-derive this pin (issue #396)"
        )

        // Ref write: FF PATCH on the existing branch / POST create on the
        // first bump, parented on the freshly fetched main tip.
        expectExactlyOneLine(
            containing: #"gh api -X PATCH "repos/${REPO}/git/refs/heads/${BRANCH}""#,
            "the update path must fast-forward the evergreen bump branch"
        )
        expectExactlyOneLine(
            containing: #"gh api -X POST "repos/${REPO}/git/refs""#,
            "the create path must create the evergreen bump branch ref"
        )
        expectExactlyOneLine(
            containing: #"PARENT="${BRANCH_SHA:-$MAIN_TIP}""#,
            "the parent selection (existing branch head, else the fetched main tip) is load-bearing"
        )
        expectExactlyOneLine(
            containing: "git fetch -q origin main",
            "the create-path parent must come from a fresh origin/main fetch"
        )

        // No-changes early exit: a forced identical rebuild must
        // notice-and-stop, never push an empty bump commit.
        let quietLines = scriptLines.enumerated().filter {
            $0.element.contains("git diff --cached --quiet")
        }
        #expect(
            quietLines.count == 1,
            "\(scriptPath) must contain exactly one `git diff --cached --quiet` early exit, found \(quietLines.count) — re-derive this pin (issue #396)"
        )
        if let quietIndex = quietLines.first?.offset {
            let following = scriptLines[(quietIndex + 1)...].prefix(4)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(
                following.contains("exit 0"),
                "the `git diff --cached --quiet` branch in \(scriptPath) must `exit 0` through the no-changes notice path (a forced identical rebuild must not push an empty bump commit) — re-derive this pin (issue #396)"
            )
        }

        // The alarm marker: exactly 3 post-ownership write sites (PR
        // discovery, update path, create path).
        let markerWrites = scriptLines.enumerated().filter {
            $0.element.contains(#"echo "probe-passed" > "$RUNNER_TEMP/ghostty-probe-ok""#)
        }
        #expect(
            markerWrites.count == 3,
            "\(scriptPath) must write the `probe-passed` alarm marker at exactly its 3 post-ownership points (PR discovery, update path, create path), found \(markerWrites.count) at line(s) \(markerWrites.map { String($0.offset + 1) }.joined(separator: ", ")) — the alarm step's at/after-PR-creation invariant breaks otherwise — re-derive this pin (issue #396)"
        )

        // Every `gh issue` call must override GH_TOKEN with GITHUB_TOKEN: the
        // app token has Contents+Pull-requests only, so issue ops silently
        // fail (duplicate canaries every run) without the override.
        let issueLines = scriptLines.enumerated().filter { $0.element.contains("gh issue ") }
        #expect(
            !issueLines.isEmpty,
            "\(scriptPath) must keep its canary `gh issue` operations — re-derive this pin (issue #396)"
        )
        let unauthenticatedIssueLines = issueLines.filter {
            !$0.element.contains(#"GH_TOKEN="$GITHUB_TOKEN""#)
        }
        #expect(
            unauthenticatedIssueLines.isEmpty,
            "every `gh issue` call in \(scriptPath) must override GH_TOKEN with GITHUB_TOKEN (the app token has no Issues permission; the silent `gh issue list` included): missing at line(s) \(unauthenticatedIssueLines.map { String($0.offset + 1) }.joined(separator: ", ")) — re-derive this pin (issue #396)"
        )

        // Canary title + search prefix must stay paired, and the title's
        // closing keyword is the only canary auto-close channel.
        expectExactlyOneLine(
            containing: #"CANARY_TITLE="ghostty bump in-flight: ${SHA7}""#,
            "the canary title shape is the dedupe key"
        )
        expectExactlyOneLine(
            containing: #"--search 'in:title "ghostty bump in-flight:"'"#,
            "the canary search prefix must match the canary title shape or every run files a duplicate canary"
        )
        expectExactlyOneLine(
            containing: #"[[ -n "$CANARY_ISSUE" ]] && PR_TITLE="${PR_TITLE} (closes #${CANARY_ISSUE})""#,
            "the `(closes #<canary>)` title suffix is the only canary auto-close channel"
        )

        // The explicit ${...} substitutions are the only expansion: bash
        // never re-expands env scalars, so a lost substitution ships literal
        // `${SHA7}` text in the PR/canary bodies.
        for substitution in [
            #"PR_BODY="${PR_BODY//\$\{SHA7\}/$SHA7}""#,
            #"PR_BODY="${PR_BODY//\$\{OLD_VERSION\}/$OLD_VERSION}""#,
            #"PR_BODY="${PR_BODY//\$\{RESOLVED_SHA\}/$RESOLVED_SHA}""#,
            #"PR_BODY="${PR_BODY//\$\{RUN_URL\}/$RUN_URL}""#,
            #"CANARY_BODY="${CANARY_BODY//\$\{SHA7\}/$SHA7}""#,
            #"CANARY_BODY="${CANARY_BODY//\$\{RESOLVED_SHA\}/$RESOLVED_SHA}""#,
            #"CANARY_BODY="${CANARY_BODY//\$\{RUN_URL\}/$RUN_URL}""#,
        ] {
            expectExactlyOneLine(
                containing: substitution,
                "the explicit placeholder substitution is the only expansion for these env bodies"
            )
        }

        // The bump commit content and the Git API invocation shape.
        expectExactlyOneLine(
            containing: #"sed -i '' "s|.*|${RESOLVED_SHA}|" scripts/patches/ghostty/BASE"#,
            "the bump must rewrite scripts/patches/ghostty/BASE to the resolved SHA"
        )
        expectExactlyOneLine(
            containing: "git add Vendor/libghostty VVTerm/Resources/terminfo scripts/patches/ghostty/BASE",
            "the bump must stage the rebuilt artifacts, terminfo and BASE"
        )
        expectExactlyOneLine(
            containing: #"PR_URL="$(gh pr create --repo "$REPO" --base main --head "$BRANCH""#,
            "the create path must bind the gh pr create invocation (the echo of the same words must not satisfy this)"
        )

        // Both merge paths must (re-)enable squash auto-merge, and both must
        // publish the bump_pr_number job output.
        expectExactlyOneLine(
            containing: #"gh pr merge "$n" --repo "$REPO" --auto --squash"#,
            "the update path must (re-)enable squash auto-merge"
        )
        expectExactlyOneLine(
            containing: #"gh pr merge "$PR_NUMBER" --repo "$REPO" --auto --squash"#,
            "the create path must enable squash auto-merge"
        )
        expectExactlyOneLine(
            containing: #"echo "bump_pr_number=${n}" >> "$GITHUB_OUTPUT""#,
            "the update path must publish the bump PR number job output"
        )
        expectExactlyOneLine(
            containing: #"echo "bump_pr_number=${PR_NUMBER}" >> "$GITHUB_OUTPUT""#,
            "the create path must publish the bump PR number job output"
        )

        // Script shape + 2-arg contract: `set -euo pipefail` is the first
        // executed line (the child bash inherits no shell options), the usage
        // check is declared, REPO/RUN_URL are bound once, and the `<<JSON`
        // heredoc's body and terminator stay at column 0 (#249 `PY`-backstop
        // analogue: an indented body changes the payload shape).
        let executedLines = scriptLines.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        #expect(
            executedLines.first == "set -euo pipefail",
            "\(scriptPath) must start its executed body with `set -euo pipefail` as the first executed line (found `\(executedLines.first ?? "<none>")`): the delegation's child bash inherits no shell options, so failures would stop aborting — re-derive this pin (issue #396)"
        )
        #expect(
            script.hasPrefix("#!/usr/bin/env bash\n# SPDX-License-Identifier: MIT\n"),
            "\(scriptPath) must keep its shebang and SPDX header — re-derive this pin (issue #396)"
        )
        expectExactlyOneLine(
            containing: #"if [ "$#" -ne 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then"#,
            "the script must declare the 2-arg contract"
        )
        expectExactlyOneLine(containing: #"REPO="$1""#, "the first argument must bind REPO")
        expectExactlyOneLine(containing: #"RUN_URL="$2""#, "the second argument must bind RUN_URL")

        let jsonOpeners = scriptLines.enumerated().filter { $0.element.contains("<<JSON") }
        #expect(
            jsonOpeners.count == 1,
            "\(scriptPath) must contain exactly one `<<JSON` heredoc, found \(jsonOpeners.count) at line(s) \(jsonOpeners.map { String($0.offset + 1) }.joined(separator: ", ")) — re-derive this pin (issue #396)"
        )
        if let openerIndex = jsonOpeners.first?.offset {
            let bodyStart = scriptLines[(openerIndex + 1)...].firstIndex {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if let bodyStart {
                let firstBodyLine = scriptLines[bodyStart]
                #expect(
                    !firstBodyLine.hasPrefix(" ") && !firstBodyLine.hasPrefix("\t"),
                    "the first non-blank line of the `<<JSON` heredoc opened at line \(openerIndex + 1) of \(scriptPath) is indented (`\(firstBodyLine.prefix(40))`): an indented body changes the payload shape — re-derive this pin (issue #396)"
                )
            } else {
                Issue.record(
                    "the `<<JSON` heredoc opened at line \(openerIndex + 1) of \(scriptPath) has no body lines — re-derive this pin (issue #396)"
                )
            }
            let jsonTerminators = scriptLines.enumerated().filter {
                $0.offset > openerIndex && $0.element == "JSON"
            }
            #expect(
                jsonTerminators.count == 1,
                "\(scriptPath) must contain exactly one column-0 `JSON` heredoc terminator after the opener, found \(jsonTerminators.count) — a lost or column-shifted terminator breaks the verified-commit API call — re-derive this pin (issue #396)"
            )
        }
    }

    /// Repo-wide expression budget (#396 doctrine): after the #249 and #396
    /// extractions, no `${{`-bearing `run: |` scalar in any workflow may
    /// exceed 10,000 escaped chars (half the 21,000 GitHub limit). The bound
    /// is deliberately far below the limit: a scalar at half the budget is
    /// one growth spurt away from a parse rejection, and for a schedule-only
    /// workflow that rejection is a silently dark schedule rather than a
    /// 0-job push run. Population floor plus positive control so a scanner
    /// that sees nothing cannot pass. Scope: `env:`/`if:`/`with:` scalars are
    /// separate expressions and inline/folded `run:` scalars are unreadable
    /// by `dedentedRunBlockScalar` (one inline expression-bearing `run:`
    /// today, 104 chars).
    @Test
    func testEveryExpressionBearingRunScalarStaysUnderTheRepoBudget() throws {
        let workflowFiles = try Self.listFiles(in: ".github/workflows", extensions: ["yml", "yaml"])
        var scanned: [(file: String, step: String, escaped: Int)] = []
        for file in workflowFiles {
            let path = ".github/workflows/\(file)"
            let source = try Self.workflowSource(path)
            let lines = source.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                guard let body = Self.dedentedRunBlockScalar(in: source, stepLineIndex: index),
                      body.contains("${{") else { continue }
                let newlineCount = body.components(separatedBy: "\n").count - 1
                let label = trimmed.hasPrefix("- name: ")
                    ? String(trimmed.dropFirst("- name: ".count))
                    : trimmed
                scanned.append((path, label, body.count + newlineCount))
            }
        }

        // Floor = the measured readable population at #396 (24 block scalars;
        // the repo's 25th expression-bearing run scalar is the 104-char inline
        // `ios-adhoc-pr.yml` one, outside this scanner's scope and recorded
        // under the bound by hand). A scanner that sees nothing must not pass.
        #expect(
            scanned.count >= 24,
            "the repo-wide budget scan saw only \(scanned.count) expression-bearing `run: |` scalars; the measured readable population at #396 is 24 (plus one unreadable inline scalar, 104 chars) — a scanner that sees nothing must not pass — re-derive this pin (issue #396)"
        )
        let overBudget = scanned.filter { $0.escaped > 10_000 }
        #expect(
            overBudget.isEmpty,
            "every `${{`-bearing `run: |` scalar must stay <= 10,000 escaped chars (half the 21,000 expression limit): \(overBudget.map { "\($0.file) :: \($0.step) = \($0.escaped)" }.sorted().joined(separator: ", ")). Extract the step body into scripts/ci/ (the #249/#396 pattern) — re-derive with the pyyaml recipe"
        )
        #expect(
            scanned.contains {
                $0.file == ".github/workflows/ghostty-upstream-probe.yml"
                    && $0.step == "Commit artifacts, push bump branch, create or reuse bump PR"
            },
            "the #396 target step must be inside the scanned set (positive control) — re-derive this pin (issue #396)"
        )
    }

    // MARK: - Fixtures

    private struct FlagOccurrence {
        let file: String
        let line: Int
        let value: String
    }

    /// Scans `-collect-test-diagnostics` values in every workflow and every
    /// `scripts/ci/*.sh` (the #249 corpus extension — the UI-shard invocation
    /// lives in `run-ui-tests.sh` now).
    private static func collectTestDiagnosticsOccurrences() throws -> [FlagOccurrence] {
        var paths: [String] = []
        for file in try listFiles(in: ".github/workflows", extensions: ["yml", "yaml"]) {
            paths.append(".github/workflows/\(file)")
        }
        for file in try listFiles(in: "scripts/ci", extensions: ["sh"]) {
            paths.append("scripts/ci/\(file)")
        }
        guard !paths.isEmpty else {
            throw PinFailure("no workflow or CI-script files to scan — re-derive this pin")
        }

        var occurrences: [FlagOccurrence] = []
        for path in paths {
            let source = try workflowSource(path)
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
                occurrences.append(FlagOccurrence(file: path, line: index + 1, value: value))
            }
        }
        return occurrences
    }

    private static func listFiles(in directory: String, extensions: Set<String>) throws -> [String] {
        let url = try repositoryRoot().appendingPathComponent(directory)
        do {
            return try FileManager.default
                .contentsOfDirectory(atPath: url.path)
                .filter { extensions.contains(($0 as NSString).pathExtension) }
                .sorted()
        } catch {
            throw PinFailure("could not list \(directory) at \(url.path): \(error) — re-derive this pin")
        }
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
        // source with a workflow and/or script mutated.
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

    /// Returns the dedented value of the `run: |` literal block scalar that
    /// belongs to the step at `stepLineIndex`, or nil when the step does not
    /// use `run: |` or does not carry exactly one step-level `run:` key.
    /// Impl lens 2 (fold round 1): measuring the first `run:` scalar is
    /// unsound when a duplicate step-level key exists (YAML is last-wins:
    /// ev-5) or when a nested `with.run` decoy precedes the real key (ev-9),
    /// so the scanner anchors to the step's own key indent (the item indent +
    /// 2) and fails closed on anything but exactly one `run: |`.
    /// Text-level YAML heuristic: the step ends at the next list item at the
    /// step's own indentation; the block's own indentation is fixed by its
    /// first non-empty line, and clip chomping leaves exactly one final
    /// newline.
    private static func dedentedRunBlockScalar(in source: String, stepLineIndex: Int) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard stepLineIndex < lines.count else { return nil }
        let stepIndent = lines[stepLineIndex].prefix { $0 == " " }.count
        let keyIndent = stepIndent + 2

        // The step block ends at the next list item at the step's indent.
        var stepEnd = lines.count
        var probe = stepLineIndex + 1
        while probe < lines.count {
            let line = lines[probe]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- "), indent == stepIndent {
                stepEnd = probe
                break
            }
            probe += 1
        }

        // Exactly one step-level `run:` key. A nested `with.run` decoy sits
        // deeper than `keyIndent`; a duplicate step-level key is counted and
        // fails closed.
        let runKeys = lines[stepLineIndex..<stepEnd].enumerated().filter { pair in
            let line = pair.element
            let indent = line.prefix { $0 == " " }.count
            return indent == keyIndent && line.trimmingCharacters(in: .whitespaces).hasPrefix("run:")
        }
        guard runKeys.count == 1, let stepLocalRun = runKeys.first?.offset else { return nil }
        let run = stepLineIndex + stepLocalRun
        guard lines[run].trimmingCharacters(in: .whitespaces) == "run: |" else { return nil }
        let runIndent = lines[run].prefix { $0 == " " }.count

        var blockIndent: Int?
        var block: [String] = []
        var cursor = run + 1
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                block.append("")
                cursor += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if blockIndent == nil {
                guard indent > runIndent else { break }
                blockIndent = indent
            }
            guard let base = blockIndent, indent >= base else { break }
            block.append(String(line.dropFirst(base)))
            cursor += 1
        }
        guard blockIndent != nil, !block.isEmpty else { return nil }
        while let last = block.last, last.isEmpty { block.removeLast() }
        return block.joined(separator: "\n") + "\n"
    }

    /// Cuts one YAML/bash-style trailing comment from a single line: a `#`
    /// at line start or preceded by whitespace starts a comment, outside
    /// single/double quotes. The file-level `strippingYAMLComments` already
    /// blanks comments, but it can be left stuck by an apostrophe (documented
    /// divergence); this per-line backstop keeps the invocation region clean
    /// in that case so a comment-only flag cannot satisfy the flag assertions
    /// (impl lens 2, Finding 6/ev-10).
    private static func cuttingLineComment(_ line: String) -> String {
        var result = ""
        var previousWasWhitespace = true
        var inSingleQuoted = false
        var inDoubleQuoted = false
        var escaped = false
        for character in line {
            if inDoubleQuoted {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inDoubleQuoted = false
                }
                previousWasWhitespace = false
                continue
            }
            if inSingleQuoted {
                result.append(character)
                if character == "'" {
                    inSingleQuoted = false
                }
                previousWasWhitespace = false
                continue
            }
            if character == "#", previousWasWhitespace {
                break
            }
            if character == "'" {
                inSingleQuoted = true
            } else if character == "\"" {
                inDoubleQuoted = true
            }
            result.append(character)
            previousWasWhitespace = character.isWhitespace
        }
        return result
    }

    /// A YAML comment-stripped copy of `source`: a `#` that starts a comment
    /// (at line start or preceded by whitespace, outside a quoted scalar)
    /// blanks the rest of the line; newlines are preserved, so line anchors
    /// still resolve. Single-quoted (`''` escapes) and double-quoted (`\`
    /// escapes) scalars are copied verbatim, so a `#` inside a scalar is not
    /// read as a comment. Duplicated from `WorkflowArtifactDependencyPinsTests`
    /// (each pin file is self-contained so it reverts independently). The
    /// bash-corpus divergence is documented in the file header.
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
