#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
simulator_id="${VVTERM_SIMULATOR_ID:-51F06FD5-9407-41DE-89B0-F9D880B97F34}"
ssh_port=22229
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-dev199.XXXXXX")"
sshd_log="$fixture_root/sshd.log"
session_input_log="$fixture_root/session-input.log"
result_bundle="${VVTERM_RESULT_BUNDLE:-/tmp/DEV199-production-reconnect.xcresult}"
keyboard_domain="com.apple.keyboard.preferences"
fixture_defaults_domain="app.vivy.vvterm.dev199-ui-test"
fixture_private_key_key="sshPrivateKeyBase64"
fixture_username_key="sshUsername"
missing_value="__VVTERM_MISSING__"
sshd_pid=""

read_keyboard_preference() {
    xcrun simctl spawn "$simulator_id" defaults read "$keyboard_domain" "$1" 2>/dev/null \
        || printf '%s\n' "$missing_value"
}

restore_keyboard_preference() {
    local key="$1"
    local value="$2"
    if [[ "$value" == "$missing_value" ]]; then
        xcrun simctl spawn "$simulator_id" defaults delete "$keyboard_domain" "$key" >/dev/null 2>&1 || true
    else
        case "$value" in
            1|true|TRUE|yes|YES) value=true ;;
            *) value=false ;;
        esac
        xcrun simctl spawn "$simulator_id" defaults write "$keyboard_domain" "$key" -bool "$value" >/dev/null 2>&1 || true
    fi
}

read_fixture_preference() {
    xcrun simctl spawn "$simulator_id" defaults read "$fixture_defaults_domain" "$1" 2>/dev/null \
        || printf '%s\n' "$missing_value"
}

restore_fixture_preference() {
    local key="$1"
    local value="$2"
    if [[ "$value" == "$missing_value" ]]; then
        xcrun simctl spawn "$simulator_id" defaults delete \
            "$fixture_defaults_domain" "$key" >/dev/null 2>&1 || true
    else
        xcrun simctl spawn "$simulator_id" defaults write \
            "$fixture_defaults_domain" "$key" -string "$value" >/dev/null 2>&1 || true
    fi
}

ensure_simulator_available_for_cleanup() {
    if xcrun simctl spawn "$simulator_id" /usr/bin/true >/dev/null 2>&1; then
        return
    fi
    xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator_id" -b >/dev/null 2>&1 || true
}

automatic_minimization="$missing_value"
hardware_keyboard_last_seen="$missing_value"
keyboard_preferences_captured=false
fixture_username="$missing_value"
fixture_private_key="$missing_value"
fixture_preferences_captured=false

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ "$keyboard_preferences_captured" == true || "$fixture_preferences_captured" == true ]]; then
        ensure_simulator_available_for_cleanup
    fi
    if [[ "$keyboard_preferences_captured" == true ]]; then
        restore_keyboard_preference AutomaticMinimizationEnabled "$automatic_minimization"
        restore_keyboard_preference HardwareKeyboardLastSeen "$hardware_keyboard_last_seen"
    fi
    if [[ "$fixture_preferences_captured" == true ]]; then
        restore_fixture_preference "$fixture_username_key" "$fixture_username"
        restore_fixture_preference "$fixture_private_key_key" "$fixture_private_key"
    fi
    if [[ -n "$sshd_pid" ]] && kill -0 "$sshd_pid" 2>/dev/null; then
        kill "$sshd_pid" 2>/dev/null || true
        wait "$sshd_pid" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -f "$sshd_log" ]]; then
        tail -100 "$sshd_log" >&2 || true
    fi
    if (( status != 0 )) && [[ -f "$session_input_log" ]]; then
        printf 'Remote PTY input:\n' >&2
        tail -100 "$session_input_log" >&2 || true
    fi
    rm -rf "$fixture_root"
    exit "$status"
}
trap cleanup EXIT INT TERM

if nc -z 127.0.0.1 "$ssh_port" 2>/dev/null; then
    printf 'Port %s is already in use; refusing to replace an existing service.\n' "$ssh_port" >&2
    exit 1
fi

ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/client_key"
read -r client_key_type client_key_body _ < "$fixture_root/client_key.pub"
printf '%s %s %s\n' "$client_key_type" "$client_key_body" 'vvterm-dev199-test' \
    > "$fixture_root/authorized_keys"
chmod 600 "$fixture_root/authorized_keys"

cat > "$fixture_root/session.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "\${SSH_ORIGINAL_COMMAND:-}" && -z "\${SSH_TTY:-}" ]]; then
    exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND"
fi

count_file="$fixture_root/connection-count"
count=0
if [[ -f "\$count_file" ]]; then
    read -r count < "\$count_file"
fi
count=\$((count + 1))
printf '%s\n' "\$count" > "\$count_file"

stty -icanon -echo min 1 time 0
printf '\033]0;DEV199_READY_%s\007' "\$count"
while IFS= read -r -n 1 key; do
    printf '%q\n' "\$key" >> "$session_input_log"
    if [[ "\$key" == x ]]; then
        printf '\033]0;DEV199_INPUT_X_%s\007' "\$count"
        printf '\033]7;file://localhost/tmp/DEV199_INPUT_X_%s\007' "\$count"
    fi
done
EOF
chmod 700 "$fixture_root/session.sh"

cat > "$fixture_root/sshd_config" <<EOF
Port $ssh_port
ListenAddress 127.0.0.1
HostKey $fixture_root/host_key
PidFile $fixture_root/sshd.pid
AuthorizedKeysFile $fixture_root/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PermitTTY yes
StrictModes no
UseDNS no
LogLevel VERBOSE
AllowUsers $(id -un)
ForceCommand $fixture_root/session.sh
Subsystem sftp internal-sftp
EOF

/usr/sbin/sshd -t -f "$fixture_root/sshd_config"
/usr/sbin/sshd -D -e -f "$fixture_root/sshd_config" > "$sshd_log" 2>&1 &
sshd_pid=$!

for _ in {1..50}; do
    if nc -z 127.0.0.1 "$ssh_port" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 "$ssh_port" 2>/dev/null; then
    printf 'Loopback sshd did not start.\n' >&2
    exit 1
fi

xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_id" -b
automatic_minimization="$(read_keyboard_preference AutomaticMinimizationEnabled)"
hardware_keyboard_last_seen="$(read_keyboard_preference HardwareKeyboardLastSeen)"
keyboard_preferences_captured=true
xcrun simctl spawn "$simulator_id" defaults write "$keyboard_domain" AutomaticMinimizationEnabled -bool false
xcrun simctl spawn "$simulator_id" defaults write "$keyboard_domain" HardwareKeyboardLastSeen -bool false
fixture_username="$(read_fixture_preference "$fixture_username_key")"
fixture_private_key="$(read_fixture_preference "$fixture_private_key_key")"
fixture_preferences_captured=true
xcrun simctl spawn "$simulator_id" defaults write \
    "$fixture_defaults_domain" "$fixture_username_key" -string "$(id -un)"
xcrun simctl spawn "$simulator_id" defaults write \
    "$fixture_defaults_domain" "$fixture_private_key_key" -string "$(base64 < "$fixture_root/client_key" | tr -d '\n')"

rm -rf "$result_bundle"
xcrun simctl terminate "$simulator_id" app.vivy.VivyTerm >/dev/null 2>&1 || true

xcodebuild test -quiet \
    -project "$repo_root/VVTerm.xcodeproj" \
    -scheme VVTerm \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:VVTermUITests/TerminalReconnectUITests/testProductionSSHForegroundReconnectRestoresTyping \
    -resultBundlePath "$result_bundle"

read -r final_connection_count < "$fixture_root/connection-count"
if [[ "$final_connection_count" != 4 ]]; then
    printf 'Expected exactly 4 PTY sessions, found %s.\n' "$final_connection_count" >&2
    exit 1
fi

xcrun xcresulttool get test-results tests --path "$result_bundle" --compact \
    | jq -e '.. | objects | select(.nodeType == "Test Case" and .name == "testProductionSSHForegroundReconnectRestoresTyping()" and .result == "Passed")' \
    >/dev/null

printf 'DEV-199 production reconnect test passed: %s\n' "$result_bundle"
