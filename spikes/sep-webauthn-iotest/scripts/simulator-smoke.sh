#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# simulator-smoke.sh — boot an iOS Simulator, build + install + launch the
# iotest app, capture the unified log, and assert the expected probe markers
# are present. Designed for the sep-webauthn-iotest-simulator.yml workflow.
#
# What this proves (CI-able):
#   - the app builds for iOS Simulator
#   - WKWebView loads https://teleport.pcad.it/web/login
#   - window.PublicKeyCredential is exposed in the webview JS context
#   - isUserVerifyingPlatformAuthenticatorAvailable() returns a value
#   - evaluateJavaScript round-trips a value back to Swift
#
# What this does NOT prove (device-only):
#   - the Face ID prompt appears on the WebAuthn ceremony
#   - passwordless login completes
#   - privilege-token re-auth works
#   - SEP-key creation with .biometryAny (simulator has no SEP)
#
# Usage:
#   scripts/simulator-smoke.sh [--scheme iotest] [--sim "iPhone 15"]
#
# Exits 0 on success, non-zero on any marker missing or build/install failure.

set -euo pipefail

SCHEME="${SCHEME:-iotest}"
SIM_NAME="${SIM_NAME:-iPhone 15}"
WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$WORKFLOW_DIR/iotest.xcodeproj"
DERIVED_DATA="$(mktemp -d -t iotest-dd)"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/iotest.app"
LOG_FILE="$(mktemp -t iotest-log).log"
BOOT_TIMEOUT=180        # seconds to wait for simulator boot
RUN_TIMEOUT=90         # seconds to wait for app to run + emit probes (incl. ceremony syntax check)
MARKER_PREFIX="[IOTEST]"

# Markers the smoke test asserts. Each must appear in the captured log.
# The ceremony_js_syntax_ok markers (session 1.7) validate the ceremony JS
# strings parse without error — two separate markers (login + privilege)
# because the checks run independently.
REQUIRED_MARKERS=(
    "app_launched"
    "load_started"
    "load_succeeded"
    "js_injection_roundtrip=2"
    "public_key_credential_exists=true"
    "platform_authenticator_available="
    "ceremony_js_syntax_ok name=login ok=true"
    "ceremony_js_syntax_ok name=privilege ok=true"
)

echo "==> Config"
echo "    scheme:      $SCHEME"
echo "    simulator:   $SIM_NAME"
echo "    project:     $PROJECT"
echo "    derivedData: $DERIVED_DATA"
echo "    app path:    $APP_PATH"
echo

# ── 1. Resolve & boot a simulator ─────────────────────────────────────────
echo "==> Resolving simulator '$SIM_NAME'"
SIM_UDID="$(xcrun simctl list devices available -j | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for d in devices:
        if d['name'] == '$SIM_NAME' and d['isAvailable']:
            print(d['udid']); sys.exit(0)
sys.exit(1)
")"
if [[ -z "$SIM_UDID" ]]; then
    echo "ERROR: no available simulator named '$SIM_NAME'" >&2
    xcrun simctl list devices available >&2
    exit 1
fi
echo "    udid:        $SIM_UDID"

echo "==> Booting simulator (timeout ${BOOT_TIMEOUT}s)"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true  # already-booted is fine
# Wait for booted state
deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
while ! xcrun simctl list devices -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data['devices'].values():
    for d in devices:
        if d['udid'] == '$SIM_UDID' and d['state'] == 'Booted':
            sys.exit(0)
sys.exit(1)
"; do
    if [[ "$(date +%s)" -gt "$deadline" ]]; then
        echo "ERROR: simulator did not boot within ${BOOT_TIMEOUT}s" >&2
        exit 1
    fi
    sleep 2
done
echo "    booted."

# Open the Simulator.app window so the UI is visible (helpful for debugging).
open -a Simulator "$SIM_UDID" 2>/dev/null || true

# ── 2. Build the app ──────────────────────────────────────────────────────
echo "==> Building $SCHEME for iOS Simulator"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination-timeout 60 \
    build 2>&1 | tee "$DERIVED_DATA/build.log"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app not built at $APP_PATH" >&2
    exit 1
fi
echo "    built: $APP_PATH"

# ── 3. Install + launch, capturing unified log ────────────────────────────
echo "==> Installing app"
xcrun simctl install "$SIM_UDID" "$APP_PATH"

BUNDLE_ID="it.pcad.vvterm.iotest"
echo "==> Launching app + capturing unified log (timeout ${RUN_TIMEOUT}s)"

# Start streaming the unified log filtered to our subsystem, to a file.
# We start the stream BEFORE launching so we don't miss the app_launched line.
( xcrun simctl spawn "$SIM_UDID" log stream \
    --predicate 'subsystem == "it.pcad.vvterm.iotest"' \
    --level debug \
    --style compact \
    > "$LOG_FILE" 2>&1 ) &
LOG_PID=$!

# Give the log stream a moment to attach.
sleep 1

# Launch the app (foreground). simctl launch returns immediately after spawn.
xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" || {
    echo "ERROR: launch failed" >&2
    kill "$LOG_PID" 2>/dev/null || true
    exit 1
}

# Wait for the probes to complete or timeout.
deadline=$(( $(date +%s) + RUN_TIMEOUT ))
all_markers_found=0
while [[ "$(date +%s)" -lt "$deadline" ]]; do
    # Check if all required markers are present in the log.
    missing=0
    for marker in "${REQUIRED_MARKERS[@]}"; do
        # grep -F (fixed-string) so the [IOTEST] prefix isn't interpreted
        # as a character class by BRE.
        if ! grep -Fq "${MARKER_PREFIX} ${marker}" "$LOG_FILE" 2>/dev/null; then
            missing=1
            break
        fi
    done
    if [[ "$missing" -eq 0 ]]; then
        all_markers_found=1
        break
    fi
    sleep 2
done

# Stop the log stream.
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

echo
echo "==> Captured log (filtered to subsystem it.pcad.vvterm.iotest)"
echo "────────────────────────────────────────────────────────────────"
cat "$LOG_FILE" || true
echo "────────────────────────────────────────────────────────────────"

echo
echo "==> Marker check"
if [[ "$all_markers_found" -ne 1 ]]; then
    echo "FAIL: not all required markers appeared within ${RUN_TIMEOUT}s"
    for marker in "${REQUIRED_MARKERS[@]}"; do
        if grep -Fq "${MARKER_PREFIX} ${marker}" "$LOG_FILE" 2>/dev/null; then
            echo "    ✓ $marker"
        else
            echo "    ✗ $marker (MISSING)"
        fi
    done
    # Leave the simulator running so a human can inspect it on a local run.
    exit 1
fi

for marker in "${REQUIRED_MARKERS[@]}"; do
    echo "    ✓ $marker"
done

echo
echo "==> SMOKE TEST PASSED"
echo "    The WKWebView scaffolding is sound. The device run is still"
echo "    required to confirm the Face ID ceremony itself."

# Clean up: terminate the app. Leave the simulator booted for local debugging.
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
