#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Mark-driven simulator screenshotter for the zmx scrollback repro.
# Polls the bytemeter HTTP state endpoint (127.0.0.1:22233); whenever a NEW
# mark appears (the UI test records phase boundaries via /mark?phase=X), waits
# briefly for the UI to settle, then captures the simulator screen with
# `xcrun simctl io booted screenshot` — so every repro phase has a real-pixel
# image of the terminal (including the Metal-rendered scrollback) on the
# runner host, without any simulator-to-host file transfer.
#
# Usage: repro-screenshotter.sh <state-port> <screenshot-dir>
# Killed by the workflow teardown step.
set -euo pipefail

STATE_PORT="${1:-22233}"
OUT_DIR="${2:-${RUNNER_TEMP:-/tmp}/screenshots}"
mkdir -p "$OUT_DIR"

# Reference screenshot before the app connects (terminal empty / harness).
xcrun simctl io booted screenshot "$OUT_DIR/ref-pre-app.png" >/dev/null 2>&1 || true

LAST_COUNT=0
while true; do
  STATE="$(curl -fsS --max-time 3 "http://127.0.0.1:$STATE_PORT/state" 2>/dev/null || true)"
  COUNT="$(printf '%s' "$STATE" | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("marks", [])))
except Exception: print("")' 2>/dev/null || true)"
  if [ -n "$COUNT" ] && [ "$COUNT" != "$LAST_COUNT" ]; then
    LAST_COUNT="$COUNT"
    # Let the UI settle after the mark was recorded.
    sleep 1.5
    PHASE="$(printf '%s' "$STATE" | python3 -c 'import json,sys
try:
    marks = json.load(sys.stdin).get("marks", [])
    print(marks[-1].get("phase", "unknown") if marks else "unknown")
except Exception: print("unknown")' 2>/dev/null || true)"
    FILE="$OUT_DIR/mark-$COUNT-$PHASE.png"
    if xcrun simctl io booted screenshot "$FILE" >/dev/null 2>&1; then
      echo "screenshot: $FILE"
    else
      echo "screenshot FAILED for mark $COUNT ($PHASE)"
    fi
  fi
  sleep 0.5
done
