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
# (the source pins in VVTermTests are frozen at authoring time).
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
find "$OBJECT_DIR" -name '*.o' -print0 \
  | xargs -0 nm 2>/dev/null \
  | awk '{print $NF}' \
  | grep 'CfZ$' \
  | grep -v -E '^_*__prof[cd]_' \
  | sort -u > "$work/mangled.txt" || true

if [ ! -s "$work/mangled.txt" ]; then
  echo "FAIL(empty-census): no CfZ symbols found under"
  echo "  $OBJECT_DIR"
  echo "A build with zero isolated synthesized deinits cannot be right (the two"
  echo "recorded exceptions — iOS GhosttyTerminalView and the generated"
  echo "ResourceBundleClass — must be present). Treat this as a broken build or a"
  echo "broken census, not as a pass."
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

# Allowlist. Two iOS-only entries, both recorded in the #294 PR:
#   1. GhosttyTerminalView — deliberate `isolated deinit` (MainActor cleanup);
#      converging it into cleanup()/dismantleUIView is follow-up #299.
#   2. ResourceBundleClass — generated (DerivedSources/GeneratedAssetSymbols.swift),
#      never instantiated, so its deinit is dead code.
# Both are asserted PRESENT as well as allowed: if one disappears (e.g. #299
# lands), this allowlist must be updated deliberately rather than silently
# shrinking the gate.
ALLOWED_GHOSTTY='^VVTerm\.GhosttyTerminalView\.__isolated_deallocating_deinit$'
ALLOWED_BUNDLE='^VVTerm\.\(ResourceBundleClass in _[0-9A-F]+\)\.__isolated_deallocating_deinit$'

unexpected=0
while IFS= read -r demangled; do
  if printf '%s\n' "$demangled" | grep -Eq "$ALLOWED_GHOSTTY|$ALLOWED_BUNDLE"; then
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
Do NOT add it to the allowlist unless it genuinely needs an isolated deinit
(cleanup that must run on the MainActor); record the reason in the PR.
EOF
  exit 1
fi

missing=0
if ! grep -Eq "$ALLOWED_GHOSTTY" "$work/demangled.txt"; then
  echo "FAIL(allowlist-stale): iOS GhosttyTerminalView's isolated deinit is gone."
  missing=$((missing + 1))
fi
if ! grep -Eq "$ALLOWED_BUNDLE" "$work/demangled.txt"; then
  echo "FAIL(allowlist-stale): the generated ResourceBundleClass isolated deinit is gone."
  missing=$((missing + 1))
fi
if [ "$missing" -ne 0 ]; then
  echo "If a recorded exception was genuinely fixed (e.g. #299 landed), update the"
  echo "allowlist in scripts/ci/check-isolated-deinit-census.sh deliberately."
  exit 1
fi

total="$(wc -l < "$work/demangled.txt" | tr -d ' ')"
echo "OK: $total isolated synthesized deinit(s), all allowlisted (iOS GhosttyTerminalView + generated ResourceBundleClass)."
