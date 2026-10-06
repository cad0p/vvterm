#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-ghostty-config.sh — load VVTerm's generated Ghostty config fixtures
# through the vendored libghostty and fail when the core reports a diagnostic.
#
# The fixture pin test (VVTermTests/GhosttyGeneratedConfigFixturePinsTests.swift)
# keeps the fixtures byte-identical to ConfigBuilder's output for the canonical
# inputs, so this script is the point where a key the vendored core rejects
# reds CI instead of only showing up in the field (issue #247).
#
# Oracle boundary (issue #381): the probe is a diagnostics oracle only. The
# core silently accepts compatibility renames (`scrollback-limit` is mapped to
# `scrollback-limit-bytes` — bytes, not lines), duplicate scalar keys (last
# wins; list-valued keys such as `font-family`/`keybind` accumulate) and key
# meaning changes, so a config can pass this check while its semantics
# drift. The alias/duplicate class is covered at the builder boundary by
# `VVTermTests/GhosttyGeneratedConfigLintTests` (inventory / duplicates /
# known aliases), in addition to the existing value-level pin in
# `GhosttyConfigBuilderTests.configContentKeepsNonFontLinesStable`. Keys whose
# type is not C-readable (`Limit`) cannot be read back, so a read-back cannot
# cover the meaning class for those `Limit`-typed keys; that half is tracked in
# issue #382.
#
# Usage: scripts/ci/check-ghostty-config.sh <config> [<config> ...]
#
# The probe is compiled on every invocation (no cache: the compile is ~0.2 s
# and a cache key can go stale). Self-tests run before the real fixtures so a
# probe that cannot fail — or a script bug — is a hard failure, never a green.
#
# bash 3.2-safe (the macOS runner bash).

set -euo pipefail

if [ "$#" -eq 0 ]; then
  printf 'usage: %s <config> [<config> ...]\n' "$(basename "$0")" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
vendor_root="$repo_root/Vendor/libghostty"
probe_source="$script_dir/ghostty-config-probe.c"
internal_library="$vendor_root/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"

# The canonical fixtures carry the app's bundled theme as a bare name
# (`theme = "Aizen Light"`), which the core resolves through
# `GHOSTTY_RESOURCES_DIR/themes` (then the XDG config dir). A developer shell
# running inside Ghostty.app exports GHOSTTY_RESOURCES_DIR to the installed
# app, so the check passed there and failed on a clean runner (CI run
# 37377696869, `theme … not found`): the check is only portable if it pins the
# repo's bundled resources itself. Overriding the variable unconditionally also
# makes a dev-host run validate the same resources CI validates (issue #247,
# impl lens 1/2/3 B1).
resources_dir="$repo_root/VVTerm/Resources/ghostty"
export GHOSTTY_RESOURCES_DIR="$resources_dir"

# The canonical theme the fixtures use; kept in sync with the pin suite's
# `canonicalTheme` (VVTermTests/GhosttyGeneratedConfigFixturePinsTests.swift).
canonical_theme="Aizen Light"

fail() {
  printf 'check-ghostty-config: %s\n' "$1" >&2
  exit 1
}

if [ ! -f "$probe_source" ]; then
  fail "probe source is missing: $probe_source"
fi
if [ ! -f "$internal_library" ]; then
  fail "vendored macOS libghostty slice is missing: $internal_library"
fi
if [ ! -f "$resources_dir/themes/$canonical_theme" ]; then
  fail "the bundled theme the canonical fixtures use is missing: $resources_dir/themes/$canonical_theme — the fixtures' bare-name theme cannot resolve (issue #247)"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/vvterm-ghostty-config.XXXXXX")"
trap 'rm -rf "$work"' EXIT

probe="$work/ghostty-config-probe"

# Compile the probe against the vendored macOS slice, then move it into place
# atomically: a partially written binary is never executed. Compile failure is
# fatal.
if ! xcrun --sdk macosx clang -O1 -o "$probe.tmp" "$probe_source" \
  -I "$vendor_root/include" \
  "$internal_library" \
  -framework Foundation -framework AppKit -framework Metal -framework MetalKit \
  -framework CoreText -framework CoreGraphics -framework QuartzCore \
  -framework IOKit -framework IOSurface -framework UniformTypeIdentifiers \
  -framework Security -framework Carbon -framework CoreVideo -framework CoreMedia \
  -framework VideoToolbox -framework AudioToolbox -framework CoreAudio \
  -framework Accelerate -framework OpenGL -framework CoreServices \
  -framework SystemConfiguration -framework Network -lc++ -lz; then
  fail "could not compile the config probe against the vendored libghostty slice"
fi
mv "$probe.tmp" "$probe"

# Run the probe on one absolute path; captures status + combined output.
probe_status=0
probe_output=""
run_probe() {
  probe_status=0
  probe_output="$("$probe" "$1" 2>&1)" || probe_status=$?
}

# Self-test A (fail-closed): a bogus key must produce a diagnostic naming it.
# Any other failure shape does not count — a probe that cannot name the key
# cannot prove the real fixtures were actually read.
bogus_config="$work/self-test-bogus.config"
printf 'totally-bogus-key-xyz = 1\n' > "$bogus_config"
run_probe "$bogus_config"
if [ "$probe_status" -eq 0 ]; then
  fail "self-test A: the probe accepted a bogus key — the check cannot fail"
fi
if ! printf '%s\n' "$probe_output" | grep -q 'totally-bogus-key-xyz'; then
  fail "self-test A: the probe reported a failure that does not name totally-bogus-key-xyz: $probe_output"
fi

# Self-test B: the production-dominant theme form (an absolute path) must load
# cleanly, so a failure in the real fixtures cannot be blamed on the theme.
theme_file="$work/self-test-theme"
printf 'background = 000000\nforeground = ffffff\n' > "$theme_file"
theme_config="$work/self-test-theme.config"
printf 'theme = "%s"\n' "$theme_file" > "$theme_config"
run_probe "$theme_config"
if [ "$probe_status" -ne 0 ]; then
  fail "self-test B: a config with an absolute-path theme must load cleanly: $probe_output"
fi

status=0
for config_path in "$@"; do
  if [ ! -f "$config_path" ]; then
    fail "config is not an existing regular file: $config_path (the probe alone exits 0 on a missing path, so this is guarded here)"
  fi
  if [ ! -s "$config_path" ]; then
    fail "config is empty: $config_path — the probe reports zero diagnostics for arbitrary text, so an empty fixture would pass silently (issue #247)"
  fi
  if ! grep -q '^font-size = ' "$config_path"; then
    fail "config does not carry the generated 'font-size = ' directive: $config_path — the probe reports zero diagnostics for arbitrary text, so the fixture shape is guarded here (issue #247)"
  fi

  absolute_dir="$(cd "$(dirname "$config_path")" 2>/dev/null && pwd)" || fail "could not resolve the directory of: $config_path"
  absolute_path="$absolute_dir/$(basename "$config_path")"

  run_probe "$absolute_path"

  printf '%s:\n' "$absolute_path"
  if [ "$probe_status" -eq 0 ]; then
    printf '  no diagnostics\n'
  elif [ "$probe_status" -eq 1 ]; then
    printf '%s\n' "$probe_output" | sed 's/^/  /'
    status=1
  else
    # Exit 2 is the probe's usage/`ghostty_init` failure; a signal or crash
    # lands anywhere else. Those are infrastructure failures, not core
    # diagnostics, and must not be reported as a rejected config (issue #247,
    # impl lens 1 finding 5).
    fail "the probe failed to run for $absolute_path (exit $probe_status) — this is an infrastructure failure, not a core diagnostic: $probe_output"
  fi
done

if [ "$status" -ne 0 ]; then
  printf '\ncheck-ghostty-config: FAILED — the vendored core rejected generated config content\n' >&2
  exit 1
fi

printf 'check-ghostty-config: OK — %d generated config(s) accepted by the vendored core\n' "$#"
