#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
resources="$repo_root/VVTerm/Resources/terminfo"
compiled=$(mktemp -d)
trap 'rm -rf "$compiled"' EXIT

for tool in tic infocmp clear od diff; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "required tool not found: $tool" >&2
        exit 1
    fi
done

tic -x -o "$compiled" "$resources/xterm-ghostty.src"

for term in xterm-ghostty ghostty; do
    bundled_dump="$compiled/$term.bundled"
    source_dump="$compiled/$term.source"
    infocmp -x -1 -A "$resources" "$term" | tail -n +2 > "$bundled_dump"
    infocmp -x -1 -A "$compiled" "$term" | tail -n +2 > "$source_dump"
    diff -u "$bundled_dump" "$source_dump"
done

TERMINFO="$compiled" infocmp -x -1 xterm-ghostty | grep -Fq 'E3=\E[3J,'

clear_bytes=$(
    TERMINFO="$compiled" TERM=xterm-ghostty clear |
        od -An -tx1 |
        tr -d ' \n'
)

expected_clear_bytes=1b5b334a1b5b481b5b324a
if [[ "$clear_bytes" != "$expected_clear_bytes" ]]; then
    echo "unexpected clear bytes: $clear_bytes (expected $expected_clear_bytes)" >&2
    exit 1
fi
