#!/usr/bin/env bash
#
# check-isolated-deinit-census.sh — #294 standing gate for the isolated
# synthesized-deinit hazard.
#
# A MainActor-isolated class with no explicit `deinit` gets a
# compiler-synthesized *isolated* deinit (`__isolated_deallocating_deinit`,
# mangled `…CfZ`). Releasing such an object outside a Swift task context takes
# the back-deployed MainActor deinit path and aborts in libmalloc (`pointer
# being freed was not allocated`) — swiftlang/swift#85663, #88036. The #294
# sweep added the empty `nonisolated deinit {}` marker to every such class; this
# step is the standing gate that catches a NEW class appearing after the sweep
# (the source pins in VVTermTests are frozen at authoring time). #299 then
# converged the iOS GhosttyTerminalView off its isolated deinit, so the sweep
# has one recorded exception left: the generated ResourceBundleClass (its
# expected distinct-symbol count is declared as EXPECTED_ALLOWLISTED below).
#
# Usage: check-isolated-deinit-census.sh <derivedDataPath>
#
# The object directory is derived from the same DerivedData root the build step
# used, so the gate cannot drift from the build it audits.
#
# Scope limitation (honest): this gate is iOS-Simulator-only, because no CI job
# builds the app for macOS. The macOS slice's declarations are protected by the
# source pins (VVTermTests/*IsolatedDeinitPinsTests.swift) plus the local
# two-platform oracle in the #294 PR; a macOS build in CI would be the only way
# to extend this gate to the macOS slice.
#
# Scope precision (GQ-8): the gate and the repo-wide source pin cover the app
# target only. VVTermLiveActivity.appex is outside both (its build configs do
# not set SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, its sources declare no
# class today, and a local nm finds zero CfZ); VVTermTests does not ship and is
# out of scope.
#
# bash 3.2-safe (the macOS runner bash): no associative arrays, no mapfile.

set -euo pipefail

DERIVED_DATA="${1:-}"
if [ -z "$DERIVED_DATA" ]; then
  echo "usage: $0 <derivedDataPath>" >&2
  exit 2
fi

OBJECT_DIR="$DERIVED_DATA/Build/Intermediates.noindex/VVTerm.build/Debug-iphonesimulator/VVTerm.build/Objects-normal/arm64"

if [ ! -d "$OBJECT_DIR" ]; then
  echo "FAIL(artifacts-not-found): the simulator object directory does not exist:"
  echo "  $OBJECT_DIR"
  echo "The census cannot run; it must not pass vacuously."
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-deinit-census.XXXXXX")"
trap 'rm -rf "$work"' EXIT
: > "$work/demangled-raw.txt"

# Allowlist. One iOS-only entry, recorded in the #294 PR:
#   ResourceBundleClass — generated (DerivedSources/GeneratedAssetSymbols.swift),
#   never instantiated, so its deinit is dead code.
# #299 removed the other recorded exception: the iOS GhosttyTerminalView now
# carries a `nonisolated deinit { … }` with a real body (and its source pin
# asserts that body).
#
# The expected distinct allowlisted count is declared here, ahead of the
# scan-evidence guards below, because those guards read it: with
# EXPECTED_ALLOWLISTED=0 the census declares an exception-free build and must
# accept a scan that finds no isolated synthesized deinits at all. It is a
# declaration that can legitimately become 0 when the last recorded exception
# disappears.
ALLOWED_BUNDLE='^VVTerm\.\(ResourceBundleClass in _[0-9A-F]+\)\.__isolated_deallocating_deinit$'

# Expected number of distinct allowlisted symbols at this head (GQ-4). Setting
# this to 0 is the supported way to declare an exception-free census; delete the
# matching allowlist entry in the same change.
EXPECTED_ALLOWLISTED=1

# Enumerate the deinit symbols. `__profc_`/`__profd_` are coverage-instrumentation
# references to the symbol name, not the deinit itself.
#
# Scan-evidence precondition (GQ-4): a small census is only trustworthy if the
# scan actually saw a build. Fail closed when the `.o` enumeration is empty or
# when `nm` produced no symbol output — those prove the scan ran and stay
# unconditional. The two "no isolated synthesized deinits were seen at all"
# guards below are conditional on EXPECTED_ALLOWLISTED so the declared
# exception-free census is reachable.
object_count="$(find "$OBJECT_DIR" -name '*.o' -print | wc -l | tr -d ' ')"
if [ "$object_count" -eq 0 ]; then
  echo "FAIL(scan-evidence): no object files found under"
  echo "  $OBJECT_DIR"
  exit 2
fi

# Raw nm capture, separated from symbol extraction (F3). The previous form
# (`2>/dev/null … || true`) defeated `set -o pipefail` and dropped per-file
# diagnostics, so an nm that failed on some objects while succeeding on others
# still satisfied the precondition and the census could go green with an
# isolated deinit present in the audited target. Fail closed on a non-zero
# status and on any stderr. Measured healthy baseline for the strict stderr
# arm: fresh 433-object app artifact, `nm` status 0, stderr 0 bytes (Apple
# llvm-nm 17.0.0, Xcode 26.3), so any stderr here is unexpected rather than
# benign.
nm_status=0
find "$OBJECT_DIR" -name '*.o' -print0 \
  | xargs -0 nm > "$work/nm-raw.txt" 2> "$work/nm-err.txt" || nm_status=$?

if [ "$nm_status" -ne 0 ] || [ -s "$work/nm-err.txt" ]; then
  echo "FAIL(scan-evidence): nm failed while scanning the $object_count object file(s) under"
  echo "  $OBJECT_DIR"
  echo "nm exit status: $nm_status"
  if [ -s "$work/nm-err.txt" ]; then
    echo "nm stderr:"
    sed 's/^/  /' "$work/nm-err.txt"
  fi
  exit 2
fi

awk '{print $NF}' "$work/nm-raw.txt" > "$work/nm-symbols.txt"

if [ ! -s "$work/nm-symbols.txt" ]; then
  echo "FAIL(scan-evidence): nm produced no symbols for the $object_count object file(s) under"
  echo "  $OBJECT_DIR"
  exit 2
fi

grep 'CfZ$' "$work/nm-symbols.txt" \
  | grep -v -E '^_*__prof[cd]_' \
  | sort -u > "$work/mangled.txt" || true

# Broken-census detector only while an exception is declared (F1): zero CfZ
# symbols is a legitimate pass only when EXPECTED_ALLOWLISTED=0 declares the
# exception-free census; the expected-count check below owns that decision.
if [ ! -s "$work/mangled.txt" ] && [ "$EXPECTED_ALLOWLISTED" -ne 0 ]; then
  echo "FAIL(empty-census): no CfZ symbols found under"
  echo "  $OBJECT_DIR"
  echo "A build with zero isolated synthesized deinits cannot be right (the one"
  echo "recorded exception — the generated ResourceBundleClass — must be present)."
  echo "Treat this as a broken build or a broken census, not as a pass."
  exit 1
fi

# Hardening: every match must be a real `…fZ` deinit symbol that demangles to
# `__isolated_deallocating_deinit`.
bad_raw=0
while IFS= read -r symbol; do
  case "$symbol" in
    *fZ) ;;
    *) echo "FAIL(protocol): symbol does not end in fZ: $symbol"; bad_raw=1 ;;
  esac
done < "$work/mangled.txt"
if [ "$bad_raw" -ne 0 ]; then
  exit 1
fi

while IFS= read -r symbol; do
  demangled="$(xcrun swift-demangle "$symbol" | sed 's/.*---> //')"
  case "$demangled" in
    *.__isolated_deallocating_deinit) printf '%s\n' "$demangled" >> "$work/demangled-raw.txt" ;;
    *)
      echo "FAIL(protocol): symbol does not demangle to __isolated_deallocating_deinit:" >&2
      echo "  $symbol -> $demangled" >&2
      exit 1
      ;;
  esac
done < "$work/mangled.txt"
sort -u "$work/demangled-raw.txt" > "$work/demangled.txt"

# Same conditional as the empty-census guard (F1): empty demangling is broken
# scan evidence only while an exception is declared.
if [ ! -s "$work/demangled.txt" ] && [ "$EXPECTED_ALLOWLISTED" -ne 0 ]; then
  echo "FAIL(scan-evidence): demangling produced no isolated synthesized deinit symbols."
  exit 1
fi

unexpected=0
allowlisted=0
: > "$work/unexpected.txt"
while IFS= read -r demangled; do
  if printf '%s\n' "$demangled" | grep -Eq "$ALLOWED_BUNDLE"; then
    allowlisted=$((allowlisted + 1))
    continue
  fi
  printf '%s\n' "$demangled" >> "$work/unexpected.txt"
  unexpected=$((unexpected + 1))
done < "$work/demangled.txt"

# Zero-match allowlist drift (F2): the branch below is the "a new class
# appeared" path, but it would also fire when the allowlist itself went stale
# (e.g. the generated class was renamed), sending the operator to the wrong
# fix. When an exception is declared and the allowlist matched nothing, report
# drift with the observed symbols instead of the new-class suggestion.
if [ "$allowlisted" -eq 0 ] && [ "$EXPECTED_ALLOWLISTED" -ne 0 ]; then
  echo "FAIL(allowlist-drift): expected $EXPECTED_ALLOWLISTED allowlisted isolated synthesized deinit symbol(s), found 0."
  echo "Observed symbols:"
  sed 's/^/  /' "$work/demangled.txt"
  cat <<'EOF'

The allowlist in scripts/ci/check-isolated-deinit-census.sh no longer matches
this build's isolated synthesized deinits. If the change is intended (e.g. a
generated class was renamed or the last exception legitimately disappeared),
update the allowlist and EXPECTED_ALLOWLISTED deliberately; do not widen the
allowlist to make the census pass.
EOF
  exit 1
fi

if [ "$unexpected" -ne 0 ]; then
  while IFS= read -r demangled; do
    echo "FAIL(unexpected-isolated-deinit): $demangled"
  done < "$work/unexpected.txt"
  cat <<'EOF'

A new MainActor-isolated class with a compiler-synthesized isolated deinit
appeared. Add the repo's standard marker at the top of the class body:

    // Explicit nonisolated deinit: the compiler-synthesized deinit of a
    // MainActor-isolated class takes the back-deployed isolated-deinit path,
    // which aborts (invalid free) when released outside a task context —
    // swiftlang/swift#85663, #88036. Empty body, no behavior change.
    nonisolated deinit {}

and pin it in the matching VVTermTests/*IsolatedDeinitPinsTests.swift suite.

A class that genuinely needs nonisolated teardown uses `nonisolated deinit { … }`
with a body — not the empty marker — and the matching pin asserts the body.
Do NOT add it to the allowlist unless it genuinely needs an *isolated* deinit
(cleanup that must run on the MainActor); record the reason in the PR.
EOF
  exit 1
fi

# Expected-set check (GQ-4): the census's contract is the declared expected
# count, not "some symbols exist". The zero-match case ("no allowlist entry
# matched any symbol") is reported as allowlist drift just above; this branch
# covers the remaining count mismatches (e.g. a stale expected N, or a recorded
# exception that legitimately disappeared while EXPECTED_ALLOWLISTED was not
# updated).
if [ "$allowlisted" -ne "$EXPECTED_ALLOWLISTED" ]; then
  echo "FAIL(allowlist-drift): expected $EXPECTED_ALLOWLISTED allowlisted isolated synthesized deinit symbol(s), found $allowlisted."
  echo "Observed symbols:"
  sed 's/^/  /' "$work/demangled.txt"
  cat <<'EOF'

The allowlist in scripts/ci/check-isolated-deinit-census.sh no longer matches
this build's isolated synthesized deinits. If the change is intended (e.g. a
generated class was renamed or the last exception legitimately disappeared),
update the allowlist and EXPECTED_ALLOWLISTED deliberately; do not widen the
allowlist to make the census pass.
EOF
  exit 1
fi

# Per-entry stale check: the expected-set check above already proved the count,
# so this is the by-name guard for the one recorded exception. It is only
# meaningful while an exception is declared (F1): with EXPECTED_ALLOWLISTED=0
# there is no recorded entry to check, and the zero-match drift branch above
# has already rejected any observed symbol.
missing=0
if [ "$EXPECTED_ALLOWLISTED" -ne 0 ]; then
  if ! grep -Eq "$ALLOWED_BUNDLE" "$work/demangled.txt"; then
    echo "FAIL(allowlist-stale): the generated ResourceBundleClass isolated deinit is gone."
    missing=$((missing + 1))
  fi
fi
if [ "$missing" -ne 0 ]; then
  echo "If a recorded exception was genuinely fixed, update the allowlist and"
  echo "EXPECTED_ALLOWLISTED in scripts/ci/check-isolated-deinit-census.sh deliberately."
  exit 1
fi

total="$(wc -l < "$work/demangled.txt" | tr -d ' ')"
if [ "$total" -eq 0 ]; then
  echo "OK: 0 isolated synthesized deinit(s); the census is declared exception-free (EXPECTED_ALLOWLISTED=0)."
else
  echo "OK: $total isolated synthesized deinit(s), all allowlisted (generated ResourceBundleClass)."
fi
