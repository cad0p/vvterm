#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Provision the zmx side of the scrollback-reload repro rig. Runs on the
# xcode-27 macOS runner ONLY (never on the dev box — the dev box's pi
# harness uses zmx itself for session persistence and must not be touched).
#
#   - downloads the static zmx tarball, extracts the binary
#   - dumps `zmx version` / `zmx help` / `zmx list` to $REPRO_DIR (artifact)
#   - writes the auto-attach login-shell fragment to ~/.zprofile + ~/.zshrc
#     (guarded by a per-job flag file; NOT armed yet)
#   - creates session `repro` and injects 8000 lines of scrollback
#   - verifies via `zmx history repro` (>= 8000 lines)
#   - arms the attach flag (login shells now exec `zmx attach repro`)
#
# Env:
#   REPRO_DIR   fixture directory (default $RUNNER_TEMP/vvterm-repro)
#   ZMX_VERSION zmx version to fetch (0.7.0)
set -euo pipefail

REPRO_DIR="${REPRO_DIR:-${RUNNER_TEMP:-/tmp}/vvterm-repro}"
ZMX_VERSION="${ZMX_VERSION:-0.7.0}"
mkdir -p "$REPRO_DIR/bin"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) ZMX_ARCH="aarch64" ;;
  x86_64) ZMX_ARCH="x86_64" ;;
  *) echo "::error::unsupported runner arch $ARCH"; exit 1 ;;
esac
ZMX_URL="https://zmx.sh/a/zmx-${ZMX_VERSION}-macos-${ZMX_ARCH}.tar.gz"
ZMX_BIN="$REPRO_DIR/bin/zmx"

echo "== downloading zmx $ZMX_VERSION ($ZMX_URL) =="
if [ ! -x "$ZMX_BIN" ]; then
  curl -fsSL -o "$REPRO_DIR/zmx.tar.gz" "$ZMX_URL"
  mkdir -p "$REPRO_DIR/zmx-extract"
  tar -xzf "$REPRO_DIR/zmx.tar.gz" -C "$REPRO_DIR/zmx-extract"
  # The tarball layout is not assumed: locate the executable.
  FOUND="$(find "$REPRO_DIR/zmx-extract" -type f -perm -u+x | head -1)"
  if [ -z "$FOUND" ]; then
    echo "::error::no executable found in zmx tarball; contents:"
    find "$REPRO_DIR/zmx-extract" -type f | head -20
    exit 1
  fi
  cp "$FOUND" "$ZMX_BIN"
  chmod +x "$ZMX_BIN"
  rm -rf "$REPRO_DIR/zmx-extract" "$REPRO_DIR/zmx.tar.gz"
fi
"$ZMX_BIN" version > "$REPRO_DIR/zmx-version.txt" 2>&1 || true
"$ZMX_BIN" help > "$REPRO_DIR/zmx-help.txt" 2>&1 || true
echo "== zmx version =="
cat "$REPRO_DIR/zmx-version.txt"
echo "== zmx help (first 40 lines) =="
head -40 "$REPRO_DIR/zmx-help.txt"

# --- auto-attach fragment ---------------------------------------------------
# Only runs for SSH login shells (the app's PTY shell), guarded by:
#   - ZMX_NO_AUTOATTACH (exported in the workflow env for all non-SSH steps)
#   - the per-job arm flag (absent until scrollback injection is done)
# `exec` replaces the login shell: when the zmx client exits (SSH drop), the
# channel closes and the app sees a shell-ended disconnect — the exact loop
# BUG A measures.
FRAGMENT="# >>> vvterm-repro-zmx (repro rig; remove both marker lines to disable)
if [ -z \"\${ZMX_NO_AUTOATTACH:-}\" ] && [ -f \"$REPRO_DIR/attach-armed\" ]; then
  exec \"$ZMX_BIN\" attach repro
fi
# <<< vvterm-repro-zmx"

for RC in "$HOME/.zprofile" "$HOME/.zshrc"; do
  if [ -f "$RC" ] && grep -q "vvterm-repro-zmx" "$RC"; then
    # Remove a previous instance of the block (same job rerun / leftover).
    python3 - "$RC" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    if line.startswith("# >>> vvterm-repro-zmx"):
        skip = True
        continue
    if line.startswith("# <<< vvterm-repro-zmx"):
        skip = False
        continue
    if not skip:
        out.append(line)
open(path, "w").writelines(out)
PY
  fi
  printf '\n%s\n' "$FRAGMENT" >> "$RC"
  echo "fragment appended to $RC"
done

# --- session + scrollback injection ------------------------------------------
echo "== injecting scrollback: zmx run repro seq 1 8000 =="
"$ZMX_BIN" run repro seq 1 8000
echo "zmx run exit: $?"

echo "== zmx list =="
"$ZMX_BIN" list > "$REPRO_DIR/zmx-list.txt" 2>&1 || true
cat "$REPRO_DIR/zmx-list.txt"

HIST_LINES="$("$ZMX_BIN" history repro 2>/dev/null | wc -l | tr -d ' ')"
echo "history lines: $HIST_LINES"
if [ "$HIST_LINES" -lt 7990 ]; then
  echo "::error::zmx history for session 'repro' has only $HIST_LINES lines (expected >= 7990); scrollback injection failed"
  exit 1
fi

touch "$REPRO_DIR/attach-armed"
echo "== armed: login shells will now exec zmx attach repro =="
echo "zmx rig ready: $ZMX_BIN (version $ZMX_VERSION)"
