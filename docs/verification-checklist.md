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
- UI (`VVTermUITests`): required when keyboard/terminal input, focus, navigation, sheets, accessibility, or platform integration changed. Run the affected class locally; CI runs the shards.
- Integration/E2E: when behavior crosses SSH/session/terminal boundaries, dispatch `teleport-e2e.yml` (real-Teleport tests are env-gated and skip locally).
- Bug/regression fixes: add a deterministic failing test first when feasible; if coverage is not possible, state the blocker and the manual validation in the PR.

## 4. Let PR CI finish

- `VVTerm PR CI` (`.github/workflows/vvterm-pr-ci.yml`): build → unit-tests + UI shards. Wall-clock target ≤ 20m; check per-shard runtimes with `gh run view <id> --json jobs`.
- `VVTerm PR OTA` (`.github/workflows/vvterm-pr-ota.yml`): installable build for device smoke.
- Treat timeouts/hangs as bugs (fix or quarantine per AGENTS.md) — do not retry them away. Exception: pre-product runner state (unattached `UIScene`, zero delivered input — Case 2a, #225) is host state, not a test hang; the shard loop retries it up to twice before failing.

## 5. Report in the PR

- Exact commands run + results (pass/fail counts).
- Residual risk and anything not automatable (device-only, live-server, macOS-only).
- Confirmation that the change kept platform parity and user-facing behavior unless a change was requested.
