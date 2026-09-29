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

# Enumerate the deinit symbols. `__profc_`/`__profd_` are coverage-instrumentation
# references to the symbol name, not the deinit itself.
#
# Scan-evidence precondition (GQ-4): a small census is only trustworthy if the
# scan actually saw a build. Fail closed when the `.o` enumeration is empty,
# when `nm` produced no symbol output, or when demangling produced nothing —
# none of those is a pass.
object_count="$(find "$OBJECT_DIR" -name '*.o' -print | wc -l | tr -d ' ')"
if [ "$object_count" -eq 0 ]; then
  echo "FAIL(scan-evidence): no object files found under"
  echo "  $OBJECT_DIR"
  exit 2
fi

find "$OBJECT_DIR" -name '*.o' -print0 \
  | xargs -0 nm 2>/dev/null \
  | awk '{print $NF}' > "$work/nm-symbols.txt" || true

if [ ! -s "$work/nm-symbols.txt" ]; then
  echo "FAIL(scan-evidence): nm produced no symbols for the $object_count object file(s) under"
  echo "  $OBJECT_DIR"
  exit 2
fi

grep 'CfZ$' "$work/nm-symbols.txt" \
  | grep -v -E '^_*__prof[cd]_' \
  | sort -u > "$work/mangled.txt" || true

if [ ! -s "$work/mangled.txt" ]; then
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

if [ ! -s "$work/demangled.txt" ]; then
  echo "FAIL(scan-evidence): demangling produced no isolated synthesized deinit symbols."
  exit 1
fi

# Allowlist. One iOS-only entry, recorded in the #294 PR:
#   ResourceBundleClass — generated (DerivedSources/GeneratedAssetSymbols.swift),
#   never instantiated, so its deinit is dead code.
# #299 removed the other recorded exception: the iOS GhosttyTerminalView now
# carries a `nonisolated deinit { … }` with a real body (and its source pin
# asserts that body).
#
# The expected distinct allowlisted count is declared below rather than implied
# by "must be non-empty": it is a declaration that can legitimately become 0
# when the last recorded exception disappears.
ALLOWED_BUNDLE='^VVTerm\.\(ResourceBundleClass in _[0-9A-F]+\)\.__isolated_deallocating_deinit$'

# Expected number of distinct allowlisted symbols at this head (GQ-4). Setting
# this to 0 is the supported way to declare an exception-free census; delete the
# matching allowlist entry in the same change.
EXPECTED_ALLOWLISTED=1

unexpected=0
allowlisted=0
while IFS= read -r demangled; do
  if printf '%s\n' "$demangled" | grep -Eq "$ALLOWED_BUNDLE"; then
    allowlisted=$((allowlisted + 1))
    continue
  fi
  echo "FAIL(unexpected-isolated-deinit): $demangled"
  unexpected=$((unexpected + 1))
done < "$work/demangled.txt"

if [ "$unexpected" -ne 0 ]; then
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
# count, not "some symbols exist". Because the unexpected loop above already
# exited on any unrecognized symbol, this is also where "no allowlist entry
# matched any symbol" surfaces — as allowlist drift, not as a suggestion to
# marker a new class.
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
# so this is the by-name guard for the one recorded exception.
missing=0
if ! grep -Eq "$ALLOWED_BUNDLE" "$work/demangled.txt"; then
  echo "FAIL(allowlist-stale): the generated ResourceBundleClass isolated deinit is gone."
  missing=$((missing + 1))
fi
if [ "$missing" -ne 0 ]; then
  echo "If a recorded exception was genuinely fixed, update the allowlist and"
  echo "EXPECTED_ALLOWLISTED in scripts/ci/check-isolated-deinit-census.sh deliberately."
  exit 1
fi

total="$(wc -l < "$work/demangled.txt" | tr -d ' ')"
echo "OK: $total isolated synthesized deinit(s), all allowlisted (generated ResourceBundleClass)."
