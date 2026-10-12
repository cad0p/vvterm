#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# ghostty-probe-bump-gate.sh — resolve the ghostty upstream probe's bump-PR
# gate (issue #435).
#
# Why this exists: the probe's `create_bump_pr` input is declared
# `type: boolean`, and GitHub Actions casts mixed comparison operands to
# numbers, so a real JSON boolean `false` compares equal to the empty string
# (`false == ''` -> `0 == 0` -> true). The old in-workflow gate
# (`inputs.create_bump_pr == '' || inputs.create_bump_pr == 'true' ||
# inputs.create_bump_pr == true`) therefore treated a `create_bump_pr=false`
# validation dispatch as the schedule arm and ran the bump steps — measured
# 2026-10-12 (run 38216971222 created bump PR #434). This script moves the
# decision out of the GitHub expression language into plain string
# comparisons, where it is unit-testable offline; the workflow passes
# `github.event_name` and the raw `inputs.create_bump_pr` value through
# `env:` and gates both consumers on this script's single stdout token.
#
# Usage: ghostty-probe-bump-gate.sh [--selftest] <event-name> <raw-input>
#
#   <event-name>  github.event_name of the probe run
#   <raw-input>   the raw inputs.create_bump_pr value (empty on `schedule`,
#                 where the `inputs` context is empty and dispatch defaults
#                 do not apply)
#
# Contract (pinned by the selftest and by
# VVTermTests/WorkflowXcodebuildFlagPinsTests.swift):
#   - stdout is exactly one token, `true` or `false` — no trailing
#     whitespace, no extra lines; every diagnostic goes to stderr;
#   - a wrong argument count (or `--selftest` with any extra argument)
#     prints usage to stderr and exits 64;
#   - fail-closed on the event axis: only `schedule` and a
#     `workflow_dispatch` whose raw input is exactly `true` enable the bump.
#
# Decision matrix:
#
#   | event             | raw input                | result |
#   |-------------------+--------------------------+--------|
#   | schedule          | (empty; input ignored)   | true   |
#   | workflow_dispatch | exactly `true`           | true   |
#   | workflow_dispatch | anything else            | false  |
#   | any other event   | anything                 | false  |
#
#   (`false`, `''`, `'false'`, `1`, `True`, `garbage` -> false: the script
#   compares strings only and never re-implements GitHub's loose equality.)
#
# `--selftest` (the only argument) runs the full matrix plus the argument
# and stdout-contract rows; it exits non-zero naming the failing row. The
# required `build` job runs it on every PR (issue #435).
#
# bash 3.2-safe (the macOS runner bash): no associative arrays, no mapfile,
# no `${var,,}`/`${var^^}`, no `&>`.

set -euo pipefail

usage() {
  printf 'usage: %s [--selftest] <event-name> <raw-input>\n' "${0##*/}" >&2
}

# resolve_gate <event-name> <raw-input> — the single decision seam.
resolve_gate() {
  case "$1" in
    schedule)
      # The weekly bump: the `inputs` context is empty on `schedule` (dispatch
      # defaults do not apply), so the event itself enables the bump. The arm
      # is whitelisted by event, not by an empty-string comparison, so a
      # boolean `false` can never fall into it.
      printf 'true'
      ;;
    workflow_dispatch)
      if [ "$2" = "true" ]; then
        printf 'true'
      else
        printf 'false'
      fi
      ;;
    *)
      # Fail-closed: any event this script does not recognize (push,
      # pull_request, a typo, ...) never enables the bump.
      printf 'false'
      ;;
  esac
}

# selftest — the offline matrix + contract battery. Runs the real CLI (not
# only resolve_gate) so argument handling, exit codes and the exact stdout
# byte shape are covered.
selftest() {
  local failures=0 rows=0 rc=0 out="" err="" bytes="" expected="" label=""
  SELFTEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-probe-bump-gate.XXXXXX")"
  trap 'rm -rf "$SELFTEST_DIR"' EXIT

  invoke() {
    # invoke <cli args...> — sets rc/out/err; errexit-safe.
    if bash "$0" "$@" >"$SELFTEST_DIR/stdout" 2>"$SELFTEST_DIR/stderr"; then
      rc=0
    else
      rc=$?
    fi
    out="$(cat "$SELFTEST_DIR/stdout")"
    err="$(cat "$SELFTEST_DIR/stderr")"
  }

  fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
  }

  expect_gate() {
    # expect_gate <label> <expected-token> <cli args...>
    label="$1"
    expected="$2"
    shift 2
    rows=$((rows + 1))
    invoke "$@"
    if [ "$rc" -ne 0 ]; then
      fail "$label: exit $rc (wanted 0)"
      return 0
    fi
    if [ "$out" != "$expected" ]; then
      fail "$label: stdout '$out' (wanted '$expected')"
      return 0
    fi
    bytes="$(wc -c <"$SELFTEST_DIR/stdout" | tr -d ' ')"
    if [ "$bytes" != "${#expected}" ]; then
      fail "$label: stdout is $bytes byte(s), wanted exactly ${#expected} (no trailing whitespace/newline)"
      return 0
    fi
    printf 'ok [%s]: %s\n' "$label" "$expected" >&2
  }

  expect_usage() {
    # expect_usage <label> <cli args...>
    label="$1"
    shift
    rows=$((rows + 1))
    invoke "$@"
    if [ "$rc" -ne 64 ]; then
      fail "$label: exit $rc (wanted 64)"
      return 0
    fi
    if [ -s "$SELFTEST_DIR/stdout" ]; then
      fail "$label: stdout must be empty (got '$out')"
      return 0
    fi
    case "$err" in
      *usage:*) ;;
      *)
        fail "$label: usage text missing from stderr (got '$err')"
        return 0
        ;;
    esac
    printf 'ok [%s]: usage + exit 64\n' "$label" >&2
  }

  # Decision matrix. `schedule` is asserted with and without a raw input to
  # pin the event-axis whitelist.
  expect_gate "schedule/<empty>" true schedule ''
  expect_gate "schedule/false" true schedule 'false'
  expect_gate "dispatch/true" true workflow_dispatch 'true'
  expect_gate "dispatch/false" false workflow_dispatch 'false'
  expect_gate "dispatch/<empty>" false workflow_dispatch ''
  expect_gate "dispatch/1" false workflow_dispatch '1'
  expect_gate "dispatch/True" false workflow_dispatch 'True'
  expect_gate "dispatch/TRUE" false workflow_dispatch 'TRUE'
  expect_gate "dispatch/garbage" false workflow_dispatch 'garbage'
  expect_gate "push/<empty>" false push ''
  expect_gate "push/true" false push 'true'
  expect_gate "pull_request/true" false pull_request 'true'

  # Argument contract.
  expect_usage "argc/0"
  expect_usage "argc/1" schedule
  expect_usage "argc/3" schedule true extra
  expect_usage "selftest+extra" --selftest schedule

  if [ "$failures" -ne 0 ]; then
    printf 'ghostty-probe-bump-gate: selftest FAILED — %s of %s row(s) red\n' "$failures" "$rows" >&2
    exit 1
  fi
  printf 'ghostty-probe-bump-gate: selftest OK — %s row(s)\n' "$rows" >&2
}

case "${1:-}" in
  --selftest)
    if [ "$#" -ne 1 ]; then
      usage
      exit 64
    fi
    selftest
    ;;
  *)
    if [ "$#" -ne 2 ]; then
      usage
      exit 64
    fi
    resolve_gate "$1" "$2"
    ;;
esac
