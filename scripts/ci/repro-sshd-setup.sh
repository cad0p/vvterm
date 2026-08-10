#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Provision the loopback sshd for the zmx scrollback-reload repro rig.
# Runs on the xcode-27 macOS runner ONLY (never on the dev box).
#
#   - generates a host key + a client keypair in $REPRO_DIR
#   - writes an sshd_config (Port 22232, pubkey-only, 127.0.0.1)
#   - starts /usr/sbin/sshd -D -f <config> via passwordless sudo
#   - runs a pubkey-auth smoke test (login shell must be /bin/zsh)
#   - writes $REPRO_DIR/vvterm-repro.env (fixture vars for the test step)
#
# Env:
#   REPRO_DIR   fixture directory (default $RUNNER_TEMP/vvterm-repro)
#   SSH_PORT    sshd port (22232)
set -euo pipefail

REPRO_DIR="${REPRO_DIR:-${RUNNER_TEMP:-/tmp}/vvterm-repro}"
SSH_PORT="${SSH_PORT:-22232}"
mkdir -p "$REPRO_DIR"

SSHD=/usr/sbin/sshd
if [ ! -x "$SSHD" ]; then
  echo "::error::no $SSHD on this runner"
  exit 1
fi

USERNAME="$(id -un)"
echo "== repro sshd: user=$USERNAME home=$HOME shell check =="
SHELL_PATH="$(dscl . -read "/Users/$USERNAME" UserShell 2>/dev/null | awk '{print $2}')"
echo "UserShell=$SHELL_PATH"
case "$SHELL_PATH" in
  */bash) echo "login shell is bash — the zmx fragment goes to ~/.bash_profile (handled)" ;;
  */zsh) echo "login shell is zsh — the zmx fragment goes to ~/.zprofile/.zshrc (handled)" ;;
  *) echo "::warning::unexpected login shell $SHELL_PATH; the zmx auto-attach fragment may not run" ;;
esac

# --- keys -----------------------------------------------------------------
if [ ! -f "$REPRO_DIR/ssh_host_ed25519_key" ]; then
  ssh-keygen -t ed25519 -N '' -C vvterm-repro-host -f "$REPRO_DIR/ssh_host_ed25519_key" >/dev/null
fi
if [ ! -f "$REPRO_DIR/client_key" ]; then
  ssh-keygen -t ed25519 -N '' -C vvterm-repro-client -f "$REPRO_DIR/client_key" >/dev/null
fi
cp "$REPRO_DIR/client_key.pub" "$REPRO_DIR/authorized_keys"
chmod 600 "$REPRO_DIR/client_key" "$REPRO_DIR/authorized_keys"

cat > "$REPRO_DIR/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey $REPRO_DIR/ssh_host_ed25519_key
PidFile none
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AuthorizedKeysFile $REPRO_DIR/authorized_keys
AllowUsers $USERNAME
LogLevel DEBUG3
PermitRootLogin no
X11Forwarding no
EOF

# --- start ----------------------------------------------------------------
if pgrep -f "sshd.*$REPRO_DIR/sshd_config" >/dev/null; then
  echo "sshd already running for this rig"
else
  # -E logfile: sshd debug (LogLevel DEBUG3) appended to sshd.log instead of
  # syslog — ground truth for who closed/reset the connection at the tap-kill
  # moment. (Plain -ddd re-exec broke the listener on macOS; sudo -E broke
  # setup historically — do not reintroduce either.)
  sudo "$SSHD" -E "$REPRO_DIR/sshd.log" -D -f "$REPRO_DIR/sshd_config" >/dev/null 2>&1 &
  SSHD_PID=$!
  echo "$SSHD_PID" > "$REPRO_DIR/sshd.pid"
  # The -E file is opened as root (sudo); the evidence dump + artifact
  # upload run as the runner user.
  sudo chown "$USERNAME" "$REPRO_DIR/sshd.log" 2>/dev/null || true
  # Wait for the listener (macOS python3 socket probe).
  for i in $(seq 1 30); do
    if python3 - "$SSH_PORT" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1)
s.close()
PY
    then
      echo "sshd listening on 127.0.0.1:$SSH_PORT (attempt $i)"
      break
    fi
    if ! kill -0 "$SSHD_PID" 2>/dev/null; then
      echo "::error::sshd exited during startup; log:"
      tail -50 "$REPRO_DIR/sshd.log" || true
      exit 1
    fi
    sleep 1
  done
  if ! python3 - "$SSH_PORT" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1)
s.close()
PY
  then
    echo "::error::sshd never came up; log:"
    tail -50 "$REPRO_DIR/sshd.log" || true
    # Fallback: dropbear via brew if sshd refuses to run.
    if command -v dropbear >/dev/null 2>&1 || brew install dropbear >/dev/null 2>&1; then
      echo "falling back to dropbear"
      dropbear -E -p "$SSH_PORT" -r "$REPRO_DIR/ssh_host_ed25519_key" \
        >>"$REPRO_DIR/sshd.log" 2>&1 &
      echo $! > "$REPRO_DIR/sshd.pid"
    else
      exit 1
    fi
  fi
fi

# --- smoke -----------------------------------------------------------------
# Note: the auto-attach fragment is NOT armed yet (no flag file), so the
# smoke sees a plain login shell.
SMOKE_OUT="$(ssh -p "$SSH_PORT" -i "$REPRO_DIR/client_key" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 -o LogLevel=ERROR \
  "$USERNAME@127.0.0.1" 'echo SSH_SMOKE_OK; echo shell=$SHELL; uname -s' 2>&1)"
echo "== smoke output =="
echo "$SMOKE_OUT"
if ! echo "$SMOKE_OUT" | grep -q SSH_SMOKE_OK; then
  echo "::error::pubkey auth smoke failed; sshd log tail:"
  tail -60 "$REPRO_DIR/sshd.log" || true
  exit 1
fi

# --- login-shell title fragment ----------------------------------------------
# The app's PTY SSH session runs an interactive login shell; its first prompt
# must emit an OSC 0 title so the reconnect/zen UI tests can wait for
# `title=DEV199_READY_1` (the dev fixture's PS1 carries the same marker), and
# OSC 7 so the cwd diagnostic tracks the shell's directory (the tests type
# into the shell and wait for `cwd=/tmp/DEV199_INPUT_X_1`). macOS bash/zsh do
# not emit either by default. The `hello` command reproduces the dev
# fixture's codex-prompt marker (`title=DEV212_CODEX_READY_1`) that
# enterCodexModes() waits for. Interactive-only, so the non-interactive smoke
# command below is unaffected. Idempotent.
TITLE_FRAGMENT="# >>> vvterm-repro-title (repro rig; remove both marker lines to disable)
case \$- in *i*) ;; *) return ;; esac
if [ -t 1 ]; then
  mkdir -p /tmp/DEV199_INPUT_X_1 /tmp/DEV199_INPUT_X_2 /tmp/DEV199_INPUT_X_3 /tmp/DEV199_INPUT_X_4 /tmp/DEV212_INPUT_X_1 /tmp/DEV212_INPUT_Z_1
  cd /tmp/DEV199_INPUT_X_1
  VVTERM_REPRO_X_COUNT=0
  VVTERM_REPRO_MODE=plain
  hello() { printf '\e]0;DEV212_CODEX_READY_1\a'; cd /tmp/DEV212_INPUT_X_1; printf '\e]7;file://%s%s\a' "\$HOSTNAME" "\$(pwd)"; VVTERM_REPRO_MODE=codex; }
  vvterm_repro_handle_key() {
    local key=\"\$1\"
    if [ \"\$VVTERM_REPRO_MODE\" = codex ]; then
      case \"\$key\" in
        z) cd /tmp/DEV212_INPUT_Z_1 ;;
        x) cd /tmp/DEV212_INPUT_X_1 ;;
      esac
    else
      VVTERM_REPRO_X_COUNT=\$((VVTERM_REPRO_X_COUNT + 1))
      cd \"/tmp/DEV199_INPUT_X_\${VVTERM_REPRO_X_COUNT}\"
    fi
    # Emit the OSC 7 cwd update directly: the readline redraw does not
    # re-evaluate PS1, so the app would never see the new directory.
    printf '\e]7;file://%s%s\a' \"\$HOSTNAME\" \"\$(pwd)\"
  }
  bind -x '\"x\": vvterm_repro_handle_key x'
  bind -x '\"z\": vvterm_repro_handle_key z'
  PS1=\"\[\e]0;DEV199_READY_1\a\]\[\e]7;file://\$HOSTNAME\$(pwd)\a\]\${PS1:-\\$ }\"
fi
# <<< vvterm-repro-title"

for RC in "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zprofile"; do
  if [ -f "$RC" ] && grep -q "vvterm-repro-title" "$RC"; then
    python3 - "$RC" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    if line.startswith("# >>> vvterm-repro-title"):
        skip = True
        continue
    if line.startswith("# <<< vvterm-repro-title"):
        skip = False
        continue
    if not skip:
        out.append(line)
open(path, "w").writelines(out)
PY
  fi
  printf '\n%s\n' "$TITLE_FRAGMENT" >> "$RC"
  echo "title fragment appended to $RC"
done

# --- fixture env ------------------------------------------------------------
PRIVATE_KEY_B64="$(base64 < "$REPRO_DIR/client_key" | tr -d '\n')"
cat > "$REPRO_DIR/vvterm-repro.env" <<EOF
VVTERM_REPRO_SSH_USERNAME=$USERNAME
VVTERM_REPRO_SSH_PRIVATE_KEY=$PRIVATE_KEY_B64
VVTERM_REPRO_SSH_PORT=22229
VVTERM_BYTEMETER_STATE_PORT=22233
EOF
echo "== fixture env written: $REPRO_DIR/vvterm-repro.env =="
echo "repro sshd ready: 127.0.0.1:$SSH_PORT user=$USERNAME"
