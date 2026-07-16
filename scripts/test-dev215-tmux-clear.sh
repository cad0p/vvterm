#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-dev215.XXXXXX")"
socket="$fixture_root/tmux.sock"
terminfo="$fixture_root/terminfo"
detacher_pid=""

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if [[ -n "$detacher_pid" ]] && kill -0 "$detacher_pid" 2>/dev/null; then
        kill "$detacher_pid" 2>/dev/null || true
        wait "$detacher_pid" 2>/dev/null || true
    fi
    tmux -S "$socket" kill-server >/dev/null 2>&1 || true
    rm -rf "$fixture_root"
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

for command in tmux tic clear od script; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done

mkdir -p "$terminfo"
tic_log="$fixture_root/tic.log"
tic -x -o "$terminfo" "$repo_root/VVTerm/Resources/terminfo/xterm-ghostty.src" 2>"$tic_log" || true
if [[ ! -f "$terminfo/78/xterm-ghostty" ]]; then
    while IFS= read -r line; do
        printf '%s\n' "$line" >&2
    done < "$tic_log"
    printf 'Unable to compile the bundled xterm-ghostty terminfo source.\n' >&2
    exit 1
fi

clear_bytes="$({ TERM=xterm-ghostty TERMINFO="$terminfo" clear || true; } | od -An -tx1 | tr -d ' \n')"
if [[ "$clear_bytes" != "1b5b334a1b5b481b5b324a" ]]; then
    printf 'Unexpected xterm-ghostty clear sequence: %s\n' "$clear_bytes" >&2
    exit 1
fi

printf -v shell_command \
    'env -i HOME=%q PATH=%q TERM=xterm-ghostty TERMINFO=%q PS1= /bin/bash --noprofile --norc -i' \
    "$HOME" "$PATH" "$terminfo"

tmux -S "$socket" -f /dev/null new-session -d -x 80 -y 12 -s baseline "$shell_command"
tmux -S "$socket" set-option -g status off
tmux -S "$socket" set-option -g history-limit 10000
tmux -S "$socket" set-option -g default-terminal xterm-ghostty
if ! tmux -S "$socket" show-options -g scroll-on-clear >/dev/null 2>&1; then
    printf 'tmux 3.3 or newer is required for the DEV-215 integration test.\n' >&2
    exit 1
fi
tmux -S "$socket" new-session -d -x 80 -y 12 -s managed "$shell_command"
tmux -S "$socket" new-session -d -x 80 -y 12 -s external "$shell_command"

capture_pane() {
    tmux -S "$socket" capture-pane -p -t "$1" -S -
}

wait_for_text() {
    local pane="$1"
    local expected="$2"
    local attempt
    for attempt in {1..200}; do
        if capture_pane "$pane" | grep -Fq "$expected"; then
            return
        fi
        sleep 0.02
    done
    printf 'Timed out waiting for %s in pane %s.\n' "$expected" "$pane" >&2
    capture_pane "$pane" >&2 || true
    exit 1
}

populate_and_clear() {
    local pane="$1"
    local prefix="$2"
    local sentinel="$3"
    local command
    command="i=1; while [ \$i -le 30 ]; do printf '${prefix}-%02d\\n' \$i; i=\$((i+1)); done; clear; printf '${sentinel}\\n'"
    tmux -S "$socket" send-keys -l -t "$pane" "$command"
    tmux -S "$socket" send-keys -t "$pane" Enter
    wait_for_text "$pane" "$sentinel"
}

populate_without_clear() {
    local pane="$1"
    local prefix="$2"
    local sentinel="$3"
    local command
    command="i=1; while [ \$i -le 30 ]; do printf '${prefix}-%02d\\n' \$i; i=\$((i+1)); done; printf '${sentinel}\\n'"
    tmux -S "$socket" send-keys -l -t "$pane" "$command"
    tmux -S "$socket" send-keys -t "$pane" Enter
    wait_for_text "$pane" "$sentinel"
}

round_trip_alternate_screen() {
    local pane="$1"
    local sentinel="$2"
    local command
    command="printf '\\033[?1049h\\033[H\\033[2JALT-SCREEN\\033[?1049l'; printf '${sentinel}\\n'"
    tmux -S "$socket" send-keys -l -t "$pane" "$command"
    tmux -S "$socket" send-keys -t "$pane" Enter
    wait_for_text "$pane" "$sentinel"
}

marker_count() {
    capture_pane "$1" | grep -c "$2" || true
}

baseline_option="$(tmux -S "$socket" display-message -p -t baseline:0.0 '#{scroll-on-clear}')"
populate_and_clear baseline:0.0 BASE __BASE_DONE__
baseline_markers="$(marker_count baseline:0.0 'BASE-')"
if [[ "$baseline_option" != "1" || "$baseline_markers" -le 0 ]]; then
    printf 'Baseline did not reproduce: option=%s markers=%s\n' "$baseline_option" "$baseline_markers" >&2
    exit 1
fi

tmux -S "$socket" set-option -wq -t 'managed:' scroll-on-clear off
tmux -S "$socket" split-window -d -t 'managed:' "$shell_command"
managed_panes=($(tmux -S "$socket" list-panes -t managed:0 -F '#{pane_id}'))
if [[ "${#managed_panes[@]}" -ne 2 ]]; then
    printf 'Expected two managed panes, found %s.\n' "${#managed_panes[@]}" >&2
    exit 1
fi
managed_primary="${managed_panes[0]}"
managed_secondary="${managed_panes[1]}"
managed_primary_option="$(tmux -S "$socket" display-message -p -t "$managed_primary" '#{scroll-on-clear}')"
managed_secondary_option="$(tmux -S "$socket" display-message -p -t "$managed_secondary" '#{scroll-on-clear}')"
external_option="$(tmux -S "$socket" display-message -p -t external:0.0 '#{scroll-on-clear}')"
if [[ "$managed_primary_option" != "0" || "$managed_secondary_option" != "0" || "$external_option" != "1" ]]; then
    printf 'Unexpected option scope: managed=%s split=%s external=%s\n' \
        "$managed_primary_option" "$managed_secondary_option" "$external_option" >&2
    exit 1
fi

populate_without_clear "$managed_secondary" MANAGED2 __MANAGED2_DONE__
round_trip_alternate_screen "$managed_secondary" __ALT_SCREEN_DONE__
populate_and_clear "$managed_primary" MANAGED1 __MANAGED1_DONE__
populate_and_clear external:0.0 EXTERNAL __EXTERNAL_DONE__

managed_primary_markers="$(marker_count "$managed_primary" 'MANAGED1-')"
managed_secondary_markers="$(marker_count "$managed_secondary" 'MANAGED2-')"
external_markers="$(marker_count external:0.0 'EXTERNAL-')"
if [[ "$managed_primary_markers" -ne 0 || "$managed_secondary_markers" -le 0 || "$external_markers" -le 0 ]]; then
    printf 'Unexpected clear scope: managed=%s sibling=%s external=%s\n' \
        "$managed_primary_markers" "$managed_secondary_markers" "$external_markers" >&2
    exit 1
fi

tmux -S "$socket" set-option -wq -t 'managed:' scroll-on-clear on
(
    for _ in {1..200}; do
        if [[ -n "$(tmux -S "$socket" list-clients -t managed -F '#{client_name}' 2>/dev/null)" ]]; then
            tmux -S "$socket" detach-client -s managed
            exit 0
        fi
        sleep 0.02
    done
    exit 1
) &
detacher_pid=$!
TERM=xterm-256color /usr/bin/script -q /dev/null \
    tmux -S "$socket" -f /dev/null new-session -A -s managed \
    \; set-option -wq -t 'managed:' scroll-on-clear off >/dev/null
wait "$detacher_pid"
detacher_pid=""

reattach_option="$(tmux -S "$socket" display-message -p -t managed: '#{scroll-on-clear}')"
attached_clients="$({ tmux -S "$socket" list-clients -t managed -F '#{client_name}' 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [[ "$reattach_option" != "0" || "$attached_clients" -ne 0 ]]; then
    printf 'Managed reattach did not restore the option: option=%s clients=%s\n' \
        "$reattach_option" "$attached_clients" >&2
    exit 1
fi

printf 'DEV-215 real tmux integration passed: baseline=%s managed=%s sibling=%s external=%s reattach=%s\n' \
    "$baseline_markers" "$managed_primary_markers" "$managed_secondary_markers" \
    "$external_markers" "$reattach_option"
