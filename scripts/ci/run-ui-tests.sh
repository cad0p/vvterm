#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Run one PR-CI UI-test shard against the prebuilt .xctestrun manifest and
# report xcodebuild's exit code. Extracted from the `Run UI tests (shard ...)`
# step of .github/workflows/vvterm-pr-ci.yml so the step stops spending the
# GitHub expression-length budget on shell text (issue #249).
#
# Usage: run-ui-tests.sh <shard-name> <needs-fixture:true|false> <only-testing:comma-list>
#   <shard-name>     matrix.shard.name - informational (logged as "shard: ...")
#   <needs-fixture>  matrix.shard.needs-fixture - "true" sources the loopback
#                    sshd rig env file before the plist injection
#   <only-testing>   matrix.shard.only-testing - comma-separated test ids;
#                    split into one repeated -only-testing: flag each
#
# Everything from `set +e` below is the parsed block scalar of the former step,
# byte-for-byte, with only the two `${{ matrix.shard.* }}` interpolations
# replaced by `$2` and `$3`.

if [ "$#" -ne 3 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
  echo "::error::usage: run-ui-tests.sh <shard-name> <needs-fixture:true|false> <only-testing:comma-list>" >&2
  exit 2
fi
case "$2" in
  true|false) ;;
  *)
    echo "::error::needs-fixture must be 'true' or 'false' (got '$2')" >&2
    exit 2
    ;;
esac
echo "shard: $1"

set +e  # GitHub Actions defaults to `bash -e`; disable so non-zero exits don't abort.
set -uo pipefail

# test-without-building with -xctestrun: run the prebuilt
# VVTermUITests.xctest from the build artifact with ZERO compilation.
# Previously `test -scheme VVTerm` recompiled because xcodebuild
# re-validates the dependency graph even when the artifact is present.
# -only-testing: restricts execution to this shard's tests.
XCRUN=$(find "$RUNNER_TEMP/DerivedData/Build/Products" -name '*.xctestrun' | head -1)
echo "Using xctestrun manifest: $XCRUN"

# Inject SCREENSHOT_DIR into the xctestrun plist's
# EnvironmentVariables dictionary. The manifest is the house route for
# the prebuilt runner — the env must travel with the pre-baked plist
# from build-for-testing, not with the shell invocation. (#416's probe
# measured on Xcode 26.3 that the TEST_RUNNER_ prefix DOES arrive under
# `test-without-building -xctestrun`; this plist route predates that
# probe and stays as the pinned mechanism — Pin 2 asserts the injected
# values.) The xctestrun v2 format nests env vars at:
#   TestConfigurations[0].TestTargets[*].EnvironmentVariables
# Use python (plistlib) to inject into every test target's dict.
#
# Also set UserAttachmentLifetime + SystemAttachmentLifetime to
# 'keepAlways' — the build-for-testing scheme defaults them to
# 'deleteOnSuccess', which drops XCTAttachment screenshots when
# tests pass (so the xcresult ends up empty).
export SCREENSHOT_DIR="$RUNNER_TEMP/screenshots"
mkdir -p "$SCREENSHOT_DIR"

# Fixture shards: source the sshd rig's env (username, private key)
# and point the harness at the sshd port directly (22232). The rig
# script writes VVTERM_REPRO_SSH_PORT=22229 for the bytemeter proxy
# used by repro-zmx.yml; PR CI has no bytemeter, so the app must
# talk to sshd itself.
if [ "$2" == "true" ]; then
  # shellcheck disable=SC1091
  # `set -a` auto-exports every var the rig env file defines (plain
  # `source` would leave them as shell-only vars, invisible to the
  # python plist injection below).
  set -a
  source "$RUNNER_TEMP/vvterm-repro/vvterm-repro.env"
  set +a
  export VVTERM_REPRO_SSH_PORT=22232
  echo "fixture: user=$VVTERM_REPRO_SSH_USERNAME port=$VVTERM_REPRO_SSH_PORT"
fi
python3 - "$XCRUN" "$SCREENSHOT_DIR" <<'PY'
import plistlib, os, sys
path, screenshot_dir = sys.argv[1], sys.argv[2]
with open(path, "rb") as f:
    data = plistlib.load(f)
# The loopback-SSH fixture tests (zen full-screen, reconnect,
# server navigation) run when VVTERM_REPRO_SSH_* reaches the test
# runner (LoopbackSSHFixtureTestSupport gates on it); the harness
# re-exports it into the app's launchEnvironment.
fixture_env = {}
for key in ("VVTERM_REPRO_SSH_USERNAME", "VVTERM_REPRO_SSH_PRIVATE_KEY", "VVTERM_REPRO_SSH_PORT", "VVTERM_REPRO_SSH_HOST_KEY_FINGERPRINT", "VVTERM_REPRO_SSH_HOST_KEY_TYPE"):
    if key in os.environ:
        fixture_env[key] = os.environ[key]
injected = 0
for cfg in data.get("TestConfigurations", []):
    for target in cfg.get("TestTargets", []):
        env = target.setdefault("EnvironmentVariables", {})
        env["SCREENSHOT_DIR"] = screenshot_dir
        env.update(fixture_env)
        # The UI-test runner's env comes from this plist (the pinned
        # mechanism; #416's probe measured the TEST_RUNNER_ prefix also
        # arriving under `test-without-building -xctestrun` on Xcode
        # 26.3). The shell's plain CI=true never reaches the runner —
        # only the plist does. Inject it explicitly so ProcessInfo checks
        # (e.g. the #45 template-test skip in VVTermUITests/testExample)
        # actually fire in CI.
        env["CI"] = "1"
        # Keep XCTAttachment screenshots even when tests pass.
        target["UserAttachmentLifetime"] = "keepAlways"
        target["SystemAttachmentLifetime"] = "keepAlways"
        injected += 1
with open(path, "wb") as f:
    plistlib.dump(data, f)
print(f"Injected SCREENSHOT_DIR + keepAlways + fixture({list(fixture_env)}) into {injected} test target(s)")
PY
echo "xctestrun plist after injection:"
python3 -c "import plistlib; d=plistlib.load(open('$XCRUN','rb')); [print(f'  target {i}: SCREENSHOT_DIR={t.get(\"EnvironmentVariables\",{}).get(\"SCREENSHOT_DIR\",\"<MISSING>\")}') for cfg in d.get('TestConfigurations',[]) for i,t in enumerate(cfg.get('TestTargets',[]))]"

# Build the -only-testing args. The matrix `only-testing` value is
# a comma-separated list, but xcodebuild requires ONE identifier per
# -only-testing flag (repeatable). A single comma-separated string
# silently resolves to an empty test set on Xcode 27 beta —
# xcodebuild runs 0 tests and exits success. Transform the string
# into repeated -only-testing: flags.
ONLY_TESTING_ARGS=""
IFS=',' read -ra TEST_IDS <<< "$3"
for id in "${TEST_IDS[@]}"; do
  ONLY_TESTING_ARGS="$ONLY_TESTING_ARGS -only-testing:$id"
done
echo "Shard test args:$ONLY_TESTING_ARGS"

# -test-timeouts-enabled + 300s execution allowance: a hanging test
# is KILLED and recorded as a failure BY NAME ("Exceeded execution
# time allowance") instead of wedging the shard until XCTest's own
# launch/activity timeouts fire — hangs become identifiable,
# skippable tests instead of silent wall-clock burn. The 300s cap is
# set from the 41-run clean population's largest sample: 274.228s
# (ServerNavigationUITests.testActiveTerminalPushPopPreservesList
# Position, 91.4% of 300s), then 264.594 / 256.121 / 244.008 /
# 220.380s (issue #248). A degraded runner can still push a long
# test past 300s and kill it (observed 2026-09-24 run 35939209454:
# killed at exactly 300.000s) — that is the allowance doing its job:
# a named failure, and a verdict to fix or quarantine, never to
# retry (AGENTS.md). The headroom is thin; fix-or-quarantine stays
# on #349/#264/#257.
#
# Parallel testing is explicitly OFF. The shard bins are packed
# from SERIAL per-test medians (recorded per-bin sums 612.9-681.7s
# plus 326.6-796.7s of per-shard overhead; observed wall clock
# 21.5-37.5m, median 27.8m), and
# `-parallel-testing-enabled YES` (the first #230 revision) instead
# ran 2 simulator clones per shard — 8 concurrent clones across the
# 4 shards — which correlates with the wedge wave and the 38-39m
# walls of run 35939209454. Pre-#230 main was effectively serial (0
# `Clone` lines, 42 classic-format test lines, XCTAssert in stdout
# in run 35915626164); parallel was never intended. There are no
# shard retries: a failed shard fails the run, and a host-state
# flake must be fixed or quarantined into a non-blocking job.
#
# Placement is load-bearing. A bare `-parallel-testing-enabled`
# consumes the FOLLOWING `-option` token as its optional YES/NO
# value, which silently made the timeout flags inert. Probe on
# Xcode 26.3: `xcodebuild test -scheme __nope__
# -parallel-testing-enabled -test-timeouts-enabled YES` →
# `error: Unknown build action 'YES'` (the timeout flag was eaten);
# the bare form without YES parses but drops the timeouts. Keep the
# timeout flags first and give every boolean an explicit value.
# Pre-boot the destination simulator so the test session never
# starts against a still-initializing boot (4 shards boot sims
# simultaneously; a boot that is not ready when xcodebuild starts
# is a recurring source of "Failed to initialize for UI testing:
# Timed out waiting for AX loaded notification" and hard
# app-launch timeouts, #43 family). Bounded poll — do NOT use
# `bootstatus -b` here (it can block forever on a wedged
# CoreSimulator).
xcrun simctl boot "iPhone 17" >/dev/null 2>&1 || true
BOOTED=0
for _ in $(seq 1 60); do
  if xcrun simctl list devices booted 2>/dev/null | grep -q "iPhone 17"; then
    BOOTED=1
    break
  fi
  sleep 2
done
if [ "$BOOTED" -ne 1 ]; then
  echo "::warning::iPhone 17 did not report Booted within 120s; continuing (xcodebuild will retry its own boot)."
fi
rm -rf "$RUNNER_TEMP/TestResults.xcresult"
xcodebuild test-without-building -collect-test-diagnostics never \
  -xctestrun "$XCRUN" \
  -destination "platform=iOS Simulator,name=iPhone 17,arch=arm64" \
  -resultBundlePath "$RUNNER_TEMP/TestResults.xcresult" \
  $ONLY_TESTING_ARGS \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 300 \
  -maximum-test-execution-time-allowance 300 \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  | tee "$RUNNER_TEMP/test.log"
XC_EXIT=${PIPESTATUS[0]}
# Preserve xcodebuild's exit code for the step status, but don't
# abort before the upload steps (which run on always()).
#
# -collect-test-diagnostics never: skip the 600s simulator diagnostic
# collection that fires after a test failure. The diagnostic collection
# (sysdiagnose, log archive) takes 600s (10m) per failed test and is
# the main source of CI wall-clock waste from flakes. The xcresult
# bundle already contains the test failure details. Use the debug-test
# job (workflow_dispatch) to capture full diagnostics when needed.
exit $XC_EXIT
