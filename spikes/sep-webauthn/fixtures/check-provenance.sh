#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Fail-closed provenance check for the committed SEP-WebAuthn fixtures.
#
# The committed set under fixtures/expected/ is the byte-exact oracle for the
# Swift SEPWebAuthn tests. The Go generator is fully deterministic (fixed
# P-256 key + RFC 6979 ECDSA), so every committed fixture must byte-match a
# fresh generator run. This script regenerates into a temp dir — it never
# writes to the committed tree — and compares all 8 files.
#
# It exists because the workflow's in-place regeneration would silently
# overwrite a tampered committed fixture before `swift test` runs. Running
# this check FIRST turns that into a hard failure: a PR that edits any
# committed fixture without regenerating fails CI.
#
# Usage:
#   ./check-provenance.sh
#
# Exit codes: 0 = committed set matches the generator; 1 = mismatch/missing/
# extra file, or the generator itself failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR="$SCRIPT_DIR/expected"

if [ ! -d "$EXPECTED_DIR" ]; then
    echo "FAIL: committed fixtures directory not found: $EXPECTED_DIR" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ regenerating fixtures into $TMP_DIR (committed tree untouched)"
"$SCRIPT_DIR/regenerate.sh" "$TMP_DIR"

fail=0

# Every committed fixture must byte-match the fresh generator output.
for committed in "$EXPECTED_DIR"/*; do
    name="$(basename "$committed")"
    fresh="$TMP_DIR/$name"
    if [ ! -f "$fresh" ]; then
        echo "FAIL: $name is committed but the generator did not produce it" >&2
        fail=1
        continue
    fi
    if cmp -s "$committed" "$fresh"; then
        echo "OK: $name"
    else
        echo "FAIL: $name differs from the generator output" >&2
        fail=1
    fi
done

# A generated file that is not committed is also a failure: drift in the
# expected set must be visible, not silently dropped by the in-place copy.
for fresh in "$TMP_DIR"/*; do
    name="$(basename "$fresh")"
    if [ ! -f "$EXPECTED_DIR/$name" ]; then
        echo "FAIL: the generator produced $name but it is not committed" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo >&2
    echo "FAIL: the committed fixtures are not the generator's output." >&2
    echo "Regenerate with spikes/sep-webauthn/fixtures/regenerate.sh and commit all 8 files." >&2
    exit 1
fi

echo "✓ committed fixtures byte-match the deterministic generator output."
