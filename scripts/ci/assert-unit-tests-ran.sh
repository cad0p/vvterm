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
#   - XCTest:        Executed [1-9][0-9]* tests
#   - Swift Testing: Test run with [1-9][0-9]* tests in [1-9][0-9]* suites
#
# Deliberately NO `Test Suite 'All tests' started` / `Selected tests`
# predicate: that root-suite banner naming is Xcode-27-unverified and the
# counts are the load-bearing predicate.
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
# `Test run with 0 tests in 0 suites`. `tail -1` takes the final (summary)
# occurrence; a log that only ever prints a zero-count summary yields an
# empty match and reds below.
xctest_line="$(grep -E 'Executed [1-9][0-9]* tests' "$LOG" | tail -1 || true)"
swift_line="$(grep -E 'Test run with [1-9][0-9]* tests in [1-9][0-9]* suites' "$LOG" | tail -1 || true)"

failed=0
if [ -z "$xctest_line" ]; then
  echo "::error::no non-zero XCTest summary matching 'Executed [1-9][0-9]* tests' in $LOG — the run executed zero tests, or the log is truncated (issue #416)" >&2
  failed=1
fi
if [ -z "$swift_line" ]; then
  echo "::error::no non-zero Swift Testing summary matching 'Test run with [1-9][0-9]* tests in [1-9][0-9]* suites' in $LOG — the run executed zero tests, or the log is truncated (issue #416)" >&2
  failed=1
fi
if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "XCTest summary: $xctest_line"
echo "Swift Testing summary: $swift_line"
echo "assert-unit-tests-ran: OK — both suites ran with non-zero counts"
