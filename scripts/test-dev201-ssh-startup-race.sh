#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-dev201.XXXXXX")"
sshd_log="$fixture_root/sshd.log"
reject_sshd_log="$fixture_root/sshd-reject-pty.log"
ssh_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
sshd_pid=""
reject_ssh_port=""
reject_sshd_pid=""
ipad_simulator_id="${VVTERM_IPAD_SIMULATOR_ID:-51F06FD5-9407-41DE-89B0-F9D880B97F34}"

run_with_timeout() {
    local timeout_seconds=$1
    shift
    python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
PY
}

configure_xctestrun() {
    local xctestrun=$1
    local private_key_base64=$2
    python3 - "$xctestrun" "$ssh_port" "$reject_ssh_port" "$(id -un)" "$private_key_base64" <<'PY'
import plistlib
import sys

path, port, rejected_pty_port, username, private_key = sys.argv[1:]
with open(path, "rb") as stream:
    root = plistlib.load(stream)

targets = []
if "VVTermTests" in root:
    targets.append(root["VVTermTests"])
for configuration in root.get("TestConfigurations", []):
    for target in configuration.get("TestTargets", []):
        if target.get("BlueprintName") == "VVTermTests":
            targets.append(target)

if len(targets) != 1:
    raise SystemExit(f"Expected one VVTermTests target in {path}, found {len(targets)}")

target = targets[0]
target.setdefault("EnvironmentVariables", {}).update({
    "VVTERM_SSH_INTEGRATION": "1",
    "VVTERM_SSH_HOST": "127.0.0.1",
    "VVTERM_SSH_PORT": port,
    "VVTERM_SSH_REJECT_PTY_PORT": rejected_pty_port,
    "VVTERM_SSH_USERNAME": username,
    "VVTERM_SSH_PRIVATE_KEY_BASE64": private_key,
})
target["TestTimeoutsEnabled"] = True
target["DefaultTestExecutionTimeAllowance"] = 30
target["MaximumTestExecutionTimeAllowance"] = 60

with open(path, "wb") as stream:
    plistlib.dump(root, stream, fmt=plistlib.FMT_BINARY)
PY
}

verify_results() {
    local result_bundle=$1
    local test_results="$fixture_root/$(basename "$result_bundle").json"
    xcrun xcresulttool get test-results tests --path "$result_bundle" --compact > "$test_results"
    python3 - "$test_results" \
        'cancellingAtEachStartupBoundaryStopsStartupAndAllowsFreshConnection()' \
        'disconnectingAtEachStartupBoundaryFailsCleanly()' \
        'rejectedPTYCleansChannelAndLeavesSessionUsable()' <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    root = json.load(stream)

passed = set()
stack = [root]
while stack:
    value = stack.pop()
    if isinstance(value, dict):
        if value.get("nodeType") == "Test Case" and value.get("result") == "Passed":
            passed.add(value.get("name"))
        stack.extend(value.values())
    elif isinstance(value, list):
        stack.extend(value)

missing = [name for name in sys.argv[2:] if name not in passed]
if missing:
    raise SystemExit("Missing passing DEV-201 tests: " + ", ".join(missing))
PY
}

run_platform_tests() {
    local label=$1
    local destination=$2
    local derived_data="$fixture_root/DerivedData-$label"
    local result_bundle="$fixture_root/DEV201-$label.xcresult"
    local accepted_before
    local rejected_before
    accepted_before="$(grep -c 'Accepted publickey' "$sshd_log" 2>/dev/null || true)"
    rejected_before="$(grep -c 'Accepted publickey' "$reject_sshd_log" 2>/dev/null || true)"

    run_with_timeout 600 xcodebuild build-for-testing -quiet \
        -project "$repo_root/VVTerm.xcodeproj" \
        -scheme VVTermUnitTests \
        -destination "$destination" \
        -derivedDataPath "$derived_data"

    local xctestrun
    xctestrun="$(find "$derived_data/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
    if [[ -z "$xctestrun" ]]; then
        printf 'VVTermUnitTests xctestrun file was not generated for %s.\n' "$label" >&2
        return 1
    fi
    configure_xctestrun "$xctestrun" "$client_key_base64"

    if ! run_with_timeout 180 xcodebuild test-without-building -quiet \
            -xctestrun "$xctestrun" \
            -destination "$destination" \
            -parallel-testing-enabled NO \
            -collect-test-diagnostics never \
            '-only-testing:VVTermTests/SSHStartupIntegrationTests/cancellingAtEachStartupBoundaryStopsStartupAndAllowsFreshConnection()' \
            '-only-testing:VVTermTests/SSHStartupIntegrationTests/disconnectingAtEachStartupBoundaryFailsCleanly()' \
            '-only-testing:VVTermTests/SSHStartupIntegrationTests/rejectedPTYCleansChannelAndLeavesSessionUsable()' \
            -resultBundlePath "$result_bundle"; then
        if [[ -d "$result_bundle" ]]; then
            xcrun xcresulttool get test-results summary \
                --path "$result_bundle" --compact >&2 || true
        fi
        return 1
    fi

    verify_results "$result_bundle"
    local accepted_after
    local rejected_after
    accepted_after="$(grep -c 'Accepted publickey' "$sshd_log" 2>/dev/null || true)"
    rejected_after="$(grep -c 'Accepted publickey' "$reject_sshd_log" 2>/dev/null || true)"
    if (( accepted_after <= accepted_before || rejected_after <= rejected_before )); then
        printf 'DEV-201 tests on %s did not authenticate to both SSH fixtures.\n' "$label" >&2
        return 1
    fi
    printf 'DEV-201 SSH startup race passed on %s.\n' "$label"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    for pid in "$sshd_pid" "$reject_sshd_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
    if (( status != 0 )) && [[ -f "$sshd_log" ]]; then
        tail -100 "$sshd_log" >&2 || true
        tail -100 "$reject_sshd_log" >&2 || true
    fi
    rm -rf "$fixture_root"
    exit "$status"
}
trap cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_root/client_key"
client_key_base64="$(base64 < "$fixture_root/client_key" | tr -d '\n')"
read -r client_key_type client_key_body _ < "$fixture_root/client_key.pub"
printf '%s %s %s\n' "$client_key_type" "$client_key_body" 'vvterm-dev201-test' \
    > "$fixture_root/authorized_keys"
chmod 600 "$fixture_root/authorized_keys"

cat > "$fixture_root/session.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
fi

exec /bin/sh
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

reject_ssh_port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
cat > "$fixture_root/sshd-reject-pty_config" <<EOF
Port $reject_ssh_port
ListenAddress 127.0.0.1
HostKey $fixture_root/host_key
PidFile $fixture_root/sshd-reject-pty.pid
AuthorizedKeysFile $fixture_root/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PermitTTY no
StrictModes no
UseDNS no
LogLevel VERBOSE
AllowUsers $(id -un)
ForceCommand $fixture_root/session.sh
Subsystem sftp internal-sftp
EOF

/usr/sbin/sshd -t -f "$fixture_root/sshd-reject-pty_config"
/usr/sbin/sshd -D -e -f "$fixture_root/sshd-reject-pty_config" > "$reject_sshd_log" 2>&1 &
reject_sshd_pid=$!

for _ in {1..50}; do
    if nc -z 127.0.0.1 "$reject_ssh_port" 2>/dev/null; then
        break
    fi
    sleep 0.1
done
if ! nc -z 127.0.0.1 "$reject_ssh_port" 2>/dev/null; then
    printf 'PTY-rejecting loopback sshd did not start.\n' >&2
    exit 1
fi

if ! xcrun simctl list devices available | grep -q "$ipad_simulator_id"; then
    printf 'Required iPad simulator is unavailable: %s\n' "$ipad_simulator_id" >&2
    exit 1
fi

run_platform_tests macOS 'platform=macOS,arch=arm64'
run_platform_tests iPad "platform=iOS Simulator,id=$ipad_simulator_id"
