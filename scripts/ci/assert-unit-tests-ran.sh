#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# assert-unit-tests-ran.sh — count-based vacuous-green guard for the
# `unit-tests` job (issue #416).
#
# `xcodebuild test-without-building` can exit 0 having executed zero tests
# (e.g. a filter or target selector that resolves to an empty set), turning
# the required `unit-tests` check green with no coverage. This guard requires
# BOTH summaries with non-zero counts and fails closed when either is absent
# or unparseable:
#
#   - XCTest:        ^[[:space:]]*[^[:alnum:]]*Executed [1-9][0-9]* tests
#   - Swift Testing: ^[[:space:]]*[^[:alnum:]]*Test run with [1-9][0-9]* tests in [1-9][0-9]* suites
#
# Both patterns are line-anchored (leading whitespace plus a non-alphanumeric
# prefix are allowed for the `✔ ` Swift Testing marker and ANSI escapes), so a
# test that merely PRINTS the summary prose — `Test note: previously Executed
# 12 tests here`, `XCTAssertEqual failed: ("no Test run with 5 tests in 1
# suites seen")` — cannot satisfy the guard (fold round 1, impl lens 2).
#
# Deliberately NO `Test Suite 'All tests' started` / `Selected tests`
# predicate: that root-suite banner naming is Xcode-27-unverified and the
# counts are the load-bearing predicate.
#
# Residual, stated honestly: `tail -1` takes the last *matching* summary, so a
# log that concatenates a counted run followed by a zero-test run would still
# pass. Not reachable in this job — one `tee` produces `$RUNNER_TEMP/test.log`
# and nothing retries or appends to it; a future reuser that concatenates
# runs must parse the last run boundary instead.
#
# Usage: assert-unit-tests-ran.sh <test-log>
#
# The log path is required so the guard reds a missing/empty log rather than
# reading stdin or a default path. Exit codes: 2 usage, 1 guard failure.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "::error::usage: assert-unit-tests-ran.sh <test-log>" >&2
  exit 2
fi

LOG="$1"
if [ ! -f "$LOG" ]; then
  echo "::error::unit-tests log not found: $LOG — failing closed (issue #416)" >&2
  exit 1
fi

# Non-zero count floor: [1-9][0-9]* cannot match `Executed 0 tests` or
# `Test run with 0 tests in 0 suites`. Line-anchored + `tail -1`: only a
# summary-shaped line is read, and the last such line is the final summary; a
# log that only ever prints a zero-count summary yields an empty match and
# reds below.
xctest_line="$(grep -E '^[[:space:]]*[^[:alnum:]]*Executed [1-9][0-9]* tests' "$LOG" | tail -1 || true)"
swift_line="$(grep -E '^[[:space:]]*[^[:alnum:]]*Test run with [1-9][0-9]* tests in [1-9][0-9]* suites' "$LOG" | tail -1 || true)"

failed=0
if [ -z "$xctest_line" ]; then
  echo "::error::no line-leading XCTest summary 'Executed [1-9][0-9]* tests' in $LOG — the run executed zero tests, the summary is missing, or the log is truncated (issue #416)" >&2
  failed=1
fi
if [ -z "$swift_line" ]; then
  echo "::error::no line-leading Swift Testing summary 'Test run with [1-9][0-9]* tests in [1-9][0-9]* suites' in $LOG — the run executed zero tests, the summary is missing, or the log is truncated (issue #416)" >&2
  failed=1
fi
if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "XCTest summary: $xctest_line"
echo "Swift Testing summary: $swift_line"
echo "assert-unit-tests-ran: OK — both suites ran with non-zero counts"
