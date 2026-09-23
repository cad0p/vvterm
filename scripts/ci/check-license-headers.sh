#!/usr/bin/env bash
#
# check-license-headers.sh — Phase 0c license-header gate.
#
# Rule: a tracked file may carry the AGPL SPDX marker only when it is listed in
# docs/teleport-derived-files.txt as "<path><TAB><reason>"; every other
# fork-new file is MIT. See THIRD_PARTY_NOTICES.md ("Teleport (ported
# portions)") and LICENSES/.
#
# Fails (exit 1) when:
#   1. a file carries the marker but is not in the allowlist;
#   2. an allowlisted path is missing from the tree, or no longer carries the
#      marker (stale allowlist);
#   3. the allowlist file's own header carries the literal marker.
#
# The scan excludes this script and the allowlist file, both of which
# necessarily mention the marker text (round-1 review BLOCKER: self-match).
#
# bash 3.2-safe (the macOS runner bash): no associative arrays, no mapfile.
# LC_ALL=C for every sort/comm so the set comparisons are byte-ordered.

set -euo pipefail

MARKER="SPDX-License-Identifier: AGPL-3.0-or-later"
ALLOWLIST="docs/teleport-derived-files.txt"
SELF="scripts/ci/check-license-headers.sh"

cd "$(git rev-parse --show-toplevel)"

work="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-license-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

status=0

fail() {
  printf 'check-license-headers: %s\n' "$1" >&2
  status=1
}

# (3) The allowlist's own header must never carry the literal marker.
if grep -q -- "$MARKER" "$ALLOWLIST"; then
  fail "$ALLOWLIST must not contain the literal marker (it would mask real entries)"
fi

# (1) Collect every marker-carrying file except this script and the allowlist.
#     `git grep` exits 1 on zero matches (not an error); >1 is a real failure.
grep_rc=0
LC_ALL=C git grep -l -- "$MARKER" -- . \
  ":(exclude)$SELF" ":(exclude)$ALLOWLIST" > "$work/agpl.raw" || grep_rc=$?
if [ "$grep_rc" -gt 1 ]; then
  fail "git grep failed (exit $grep_rc) while scanning for the AGPL marker"
fi
LC_ALL=C sort < "$work/agpl.raw" > "$work/agpl"

# Allowlist entries: "<path><TAB><reason>"; skip blank and comment lines.
LC_ALL=C grep -v -e '^[[:space:]]*$' -e '^#' "$ALLOWLIST" \
  | cut -f1 \
  | LC_ALL=C sort > "$work/allow" || true

# (2) Stale allowlist: every entry must exist and still carry the marker.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ ! -f "$path" ]; then
    fail "allowlisted path is missing from the tree: $path"
  elif ! grep -q -- "$MARKER" "$path"; then
    fail "allowlisted path no longer carries the AGPL marker (stale allowlist): $path"
  fi
done < "$work/allow"

# (1) Unlisted marker-carrying files: left-only lines of the set difference.
unlisted="$(LC_ALL=C comm -23 "$work/agpl" "$work/allow")"
if [ -n "$unlisted" ]; then
  fail "AGPL marker found on file(s) not in the allowlist:"
  printf '%s\n' "$unlisted" | sed 's/^/  /' >&2
fi

if [ "$status" -ne 0 ]; then
  printf '\ncheck-license-headers: FAILED\n' >&2
  printf 'Diff-able symmetric difference (marker files vs allowlist, LC_ALL=C comm -3):\n' >&2
  LC_ALL=C comm -3 "$work/agpl" "$work/allow" | sed 's/^/  /' >&2 || true
  exit 1
fi

printf 'check-license-headers: OK — %s marker-carrying file(s), all allowlisted in %s\n' \
  "$(wc -l < "$work/agpl" | tr -d ' ')" "$ALLOWLIST"
