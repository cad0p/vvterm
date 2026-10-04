# Verification checklist

The authoritative policy lives in [`AGENTS.md`](../AGENTS.md) — **Testing and Regression Policy**,
**Refactoring Rules**, and **CI Performance Budget**. This file only enumerates the concrete steps;
if it ever disagrees with AGENTS.md, AGENTS.md wins.

Use it before marking a non-documentation PR ready for review.

## 1. Scope the change

- Identify the touched ownership area (`Core/*`, `Features/<Feature>`, `App/*`, CI, docs) and re-read the matching AGENTS.md rules.
- Confirm the diff matches a single intent and the commits are atomic.

## 2. Build both platforms

Documentation-only changes can skip this.

- iOS Simulator (arm64):

  ```sh
  xcodebuild build -scheme VVTerm -configuration Debug \
    -destination "platform=iOS Simulator,name=iPhone 17,arch=arm64" \
    -derivedDataPath "$PWD/Build/DerivedData" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
  ```

- macOS (arm64):

  ```sh
  xcodebuild build -scheme VVTerm -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$PWD/Build/DerivedData-mac"
  ```

- Platform UI splits (`Type+iOS.swift` / `Type+macOS.swift`): both builds are required.

## 3. Run the narrowest reliable tests

- Unit: `xcodebuild test -scheme VVTermUnitTests -destination "platform=iOS Simulator,name=iPhone 17,arch=arm64" -only-testing:VVTermTests/<Suite>`
- Artifact-dependency gate (CI, issue #316): `python3 scripts/ci/check-artifact-dependencies.py --selftest` then `python3 scripts/ci/check-artifact-dependencies.py` — the exact commands the required `build` job runs right after the license gate. Rule: every in-workflow artifact downloader needs a transitive `needs:` path to the job that uploads it; a recognized cross-run `run-id:` handoff is the only exclusion; anything the fail-closed subset parser cannot prove is a `file:line` refusal. Fixture expectations are exact in `scripts/ci/fixtures/artifact-dependency/manifest.py`.
- Teleport pump-fd lifecycle (issue #237): `SSHTLSTransportPumpFDCloserTests` (XCTest) — **11 cases** after the shutdown/release split (3 before): the closer state machine, the cancellation-aware write helper, the join-before-release ordering, the connect-failure gate, and the source pins for both `SSHTLSTransport.swift` and `SSHProxySubsystemTransport.swift`. Run it with `-only-testing:VVTermTests/SSHTLSTransportPumpFDCloserTests`; `SSHTLSTransportTests` and `SSHProxySubsystemTransportTests` exercise the same pump against the loopback fixture.
- UI (`VVTermUITests`): required when keyboard/terminal input, focus, navigation, sheets, accessibility, or platform integration changed. Run the affected class locally; CI runs the shards. Adding a UI test requires scheduling it in a shard `only-testing` list (plus the `scripts/ci/shard-split-medians.json` refresh) or adding a reasoned, tracked exemption row in `scripts/ci/ui-test-allowlist.json`; new exemptions additionally require an in-code `XCTSkip` with a live tracker (the ledger is closed to pre-existing debt); `WorkflowShardSplitPinsTests` assertions 7-8 enforce the name-exact partition.
- Integration/E2E: when behavior crosses SSH/session/terminal boundaries, dispatch `teleport-e2e.yml` (real-Teleport tests are env-gated and skip locally).
- Bug/regression fixes: add a deterministic failing test first when feasible; if coverage is not possible, state the blocker and the manual validation in the PR.

## 4. Let PR CI finish

- `VVTerm PR CI` (`.github/workflows/vvterm-pr-ci.yml`): build → unit-tests + 4 UI shards. Wall-clock target ≤ 20m (`build` + the slowest shard); the 2026-10-04 refresh measured per-bin sums of per-method medians of 549.6–681.7 s plus 326.6–796.7 s of per-shard setup/overhead, i.e. an observed wall clock of **21.5–37.5 m** (median 27.8 m) — the ≤ 20 m target is currently unmet and is recorded as a residual on #248, not fixed by the table refresh. Check per-shard runtimes with `gh run view <id> --json jobs`.
- Event gating (issue #315): `wait-for-ota-publish`, `unit-tests` and the `ui-tests` matrix are gated to `pull_request` with the compound gate `github.event_name == 'pull_request' || github.event.inputs.debug_test == ''`. A `workflow_dispatch` with `debug_test` set therefore executes exactly `build` + `debug-test` (2 macOS jobs, peak 1, sequential); `build` stays ungated because `debug-test` consumes its `vvterm-build` artifact. An empty `debug_test` dispatch still runs the full per-PR matrix (the documented on-demand mode).
- Dispatch verification (post-merge, on `main`; do not dispatch on a PR branch — it attaches fresh `build` check runs to the graded head):

  ```sh
  gh workflow run vvterm-pr-ci.yml --ref main \
    -f debug_test=<test identifier> -f debug_timeout=600
  # wait for the run to reach `completed` (needs-dependent jobs appear in the
  # jobs API only after their dependency completes), then:
  gh run view <id> --json jobs --jq '[.jobs[] | select(.conclusion != "skipped") | .name] | sort'
  # must equal ["build","debug-test"]
  gh run view <id> --json jobs --jq '[.jobs[] | select(.conclusion == "skipped") | .name] | sort'
  # record verbatim; must contain wait-for-ota-publish, unit-tests and the
  # ui-tests entry(ies). Skipped jobs ARE listed by the jobs API.
  ```
- `VVTerm PR OTA` (`.github/workflows/vvterm-pr-ota.yml`): installable build for device smoke.
- Treat timeouts/hangs as bugs (fix or quarantine per AGENTS.md) — shards do not retry: a failed shard fails the run. A per-test execution-allowance kill is a verdict, not an infra signature. The four `ui-tests-shard-*` jobs are **not required checks** (`gh-ruleset-main` requires only `build` and `unit-tests`), so a red shard **reports without blocking the merge and needs no unblock**: classify it, record its run/job URL on the host-state flake tracker **#257**, and fix or quarantine the class. Do not re-run a shard to turn it green.
- The one exception is a shard that fails with **zero `Test Case` lines** in its `test.log` — a pre-test runner infra wedge, not a test defect, and it produced no information at all. Re-run that job (`gh run rerun --failed`); never quarantine a healthy test for it. When a test genuinely cannot be fixed, take it out of the hot path with `XCTSkip` referencing an issue.

## 5. Report in the PR

- Exact commands run + results (pass/fail counts).
- Residual risk and anything not automatable (device-only, live-server, macOS-only).
- Confirmation that the change kept platform parity and user-facing behavior unless a change was requested.
