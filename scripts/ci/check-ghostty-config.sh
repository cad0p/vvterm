#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# check-ghostty-config.sh — load VVTerm's generated Ghostty config fixtures
# through the vendored libghostty, fail when the core reports a diagnostic,
# and assert that the core applies the emitted value for every controlled
# C-readable key (issue #382).
#
# The fixture pin test (VVTermTests/GhosttyGeneratedConfigFixturePinsTests.swift)
# keeps the fixtures byte-identical to ConfigBuilder's output for the canonical
# inputs, so this script is the point where a key the vendored core rejects
# reds CI instead of only showing up in the field (issue #247).
#
# Oracle boundary (issue #381): the probe's diagnostics loop is a diagnostics
# oracle only. The core silently accepts compatibility renames
# (`scrollback-limit` is mapped to `scrollback-limit-bytes` — bytes, not
# lines), duplicate scalar keys (last wins; list-valued keys such as
# `font-family`/`keybind` accumulate) and key meaning changes, so a config can
# pass the diagnostics loop while its semantics drift. The alias/duplicate
# class is covered at the builder boundary by
# `VVTermTests/GhosttyGeneratedConfigLintTests` (inventory / duplicates /
# known aliases), in addition to the value-level pin in
# `GhosttyConfigBuilderTests.configContentKeepsNonFontLinesStable`.
#
# Read-back positive controls (issue #382): after the diagnostics loop the
# probe reads each controlled key back through `ghostty_config_get` and this
# script asserts that the applied value equals the value the fixture emitted
# (presence-only for the `shell-integration-features` bitfield, which has no
# text form). That is the readable subset's core-side oracle: a rename, alias
# demotion or tag respelling that leaves the emitted spelling *accepted* now
# reds the required `build` job, naming the key and the vendored core commit
# (`Vendor/libghostty/VERSION`). Every read-back failure cites that commit.
#
# Caveats (the #382 waiver ledger): a core transform that preserves the
# printed value is invisible to this check — a 1:1 unit change, or a semantic
# change that maps to the same f32 (e.g. pt vs px). The bool sink also cannot
# distinguish a correct 1-byte `false` from a wrong-width 4-byte
# `0x00000000` write: both print `false`.
#
# Seven emitted keys (the `window-padding-x`/`window-padding-y` pair is two keys)
# are deliberately waived: they have no C-readable cval and
# read `ok=0` at every sink, measured at
# `e77b2309fca3a27db1123a4f904b7fb432ee7162` — `font-family` (list),
# `window-padding-x` / `window-padding-y` (`WindowPadding` structs), `theme`,
# `scrollback-limit-lines` (`Limit`), `mouse-scroll-multiplier` (struct) and
# `keybind` (list). The durability ledger (the measured table, the
# caught/waived split and the reasons) lives on issue #382.
#
# Re-waiver procedure (issue #382): when a libghostty bump makes a controlled
# key `ok=0` (this script reds naming it), or upstream moves a key between the
# readable and waived sets, re-run a throwaway read-back measurement against
# the new `Vendor/libghostty/VERSION` — two synthetic configs per key, one
# value changed — then either add the key to the controlled set (probe call +
# script assertion) and re-green, or record it in the waiver ledger on issue
# #382 with the new core commit, the measured table and the reason. This PR
# carries `(closes #382)`, so a re-waiver reopens #382 or opens a follow-up
# issue labeled `ghostty-patch` and links the new waiver there. Trigger: any
# bump-PR diff that touches config key names or types under the core's
# `Config`/`src/config`.
#
# Usage: scripts/ci/check-ghostty-config.sh <config> [<config> ...]
#
# The probe is compiled on every invocation (no cache: the compile is ~0.2 s
# and a cache key can go stale). Self-tests run before the real fixtures so a
# probe that cannot fail — or a script bug — is a hard failure, never a green.
#
# bash 3.2-safe (the macOS runner bash).

set -euo pipefail

# Deterministic text comparison (and grep/sed behavior) on dev hosts and the
# runner alike (issue #382 plan §3.2 / lens 3 F5).
export LC_ALL=C

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

# The vendored core commit, cited in every read-back failure (issue #382).
core_commit="<missing Vendor/libghostty/VERSION>"
if [ -f "$vendor_root/VERSION" ]; then
  core_commit="$(tr -d '[:space:]' < "$vendor_root/VERSION")"
fi

# The controlled value keys (issue #382): the eight always-emitted keys plus
# `macos-option-as-alt`, which the iOS fixture legitimately does not emit. The
# bitfield key is asserted presence-only in its own block.
controlled_keys="font-size window-inherit-font-size cursor-style-blink cursor-style window-padding-balance window-padding-color clipboard-read shell-integration macos-option-as-alt"

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

# assert_readback <probe-output> <description> <key> <expected-value>
#
# Fails (naming the key, the description and the core commit) unless the probe
# output carries exactly one anchored `readback <key> ok=1 value=<v>` line
# whose value is <expected-value>. Called directly — never inside `$( … )` —
# so `fail` ends this script, not a subshell.
assert_readback() {
  output="$1"
  description="$2"
  key="$3"
  expected="$4"

  if ! lines="$(printf '%s\n' "$output" | grep "^readback ${key} ok=")"; then
    fail "${description}: the probe printed no anchored read-back line for '${key}' (expected '^readback ${key} ok=[01] value=') — core ${core_commit}"
  fi

  count="$(printf '%s\n' "$lines" | grep -c .)"
  if [ "$count" -ne 1 ]; then
    fail "${description}: the probe printed ${count} anchored read-back lines for '${key}' (expected exactly one) — core ${core_commit}"
  fi

  case "$lines" in
    "readback ${key} ok=0 value="*)
      fail "${description}: core ${core_commit} no longer gives '${key}' a C-readable value (ok=0) — renamed/aliased or no cval? Re-measure and update the waiver ledger on issue #382"
      ;;
    "readback ${key} ok=1 value="*)
      value="${lines#readback ${key} ok=1 value=}"
      ;;
    *)
      fail "${description}: malformed anchored read-back line for '${key}': ${lines} — core ${core_commit}"
      ;;
  esac

  if [ -z "$value" ]; then
    fail "${description}: empty read-back value for '${key}' — core ${core_commit}"
  fi
  if [ "$value" != "$expected" ]; then
    fail "${description}: core ${core_commit} read back '${key} = ${value}' but the config emitted '${key} = ${expected}' — the key's meaning or tag spelling changed; re-measure and update the waiver ledger on issue #382"
  fi
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

# Self-test C (issue #382 positive control): fixture-foreign values for
# every read-back shape family — f32, bool and all six enum keys — so a probe
# that hardcodes either fixture's text cannot pass, and the exit status is
# asserted (a reporter that exits non-zero on a clean config must not read as
# green).
selftest_readback_config="$work/self-test-readback.config"
printf 'font-size = 17\nwindow-inherit-font-size = true\ncursor-style-blink = false\ncursor-style = bar\nwindow-padding-balance = true\nwindow-padding-color = background\nclipboard-read = allow\nshell-integration = fish\nmacos-option-as-alt = right\n' > "$selftest_readback_config"
run_probe "$selftest_readback_config"
if [ "$probe_status" -ne 0 ]; then
  fail "self-test C: a clean synthetic config must exit 0 (got $probe_status) — core ${core_commit}: $probe_output"
fi
assert_readback "$probe_output" "self-test C" "font-size" "17"
assert_readback "$probe_output" "self-test C" "window-inherit-font-size" "true"
assert_readback "$probe_output" "self-test C" "cursor-style-blink" "false"
assert_readback "$probe_output" "self-test C" "cursor-style" "bar"
assert_readback "$probe_output" "self-test C" "window-padding-balance" "true"
assert_readback "$probe_output" "self-test C" "window-padding-color" "background"
assert_readback "$probe_output" "self-test C" "clipboard-read" "allow"
assert_readback "$probe_output" "self-test C" "shell-integration" "fish"
assert_readback "$probe_output" "self-test C" "macos-option-as-alt" "right"

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
    fail "the probe failed to run for $absolute_path (exit $probe_status) — this is an infrastructure failure, not a core diagnostic (possible probe crash from a changed key type/width): $probe_output"
  fi

  # Read-back positive controls (issue #382): every controlled key the
  # fixture emits must read back the exact emitted text. Diagnostics above
  # catch rejection; this catches the readable subset's alias/meaning class.
  for key in $controlled_keys; do
    if ! expected_lines="$(grep "^${key} = " "$absolute_path")"; then
      if [ "$key" = "macos-option-as-alt" ]; then
        # Legitimately absent on the iOS variant (issue #382 key set).
        continue
      fi
      fail "controlled key '${key}' is missing from $absolute_path — the fixture no longer emits it; regenerate the fixture and update the waiver ledger on issue #382 (core ${core_commit})"
    fi

    expected_count="$(printf '%s\n' "$expected_lines" | grep -c .)"
    if [ "$expected_count" -ne 1 ]; then
      fail "controlled key '${key}' appears ${expected_count} times in $absolute_path (expected exactly one anchored '^${key} = ' line) — core ${core_commit}"
    fi
    expected_value="${expected_lines#${key} = }"
    if [ -z "$expected_value" ]; then
      fail "controlled key '${key}' has an empty value in $absolute_path — core ${core_commit}"
    fi

    if ! actual_lines="$(printf '%s\n' "$probe_output" | grep "^readback ${key} ok=")"; then
      fail "the probe printed no anchored read-back line for controlled key '${key}' on $absolute_path (expected '^readback ${key} ok=[01] value=') — core ${core_commit}"
    fi

    actual_count="$(printf '%s\n' "$actual_lines" | grep -c .)"
    if [ "$actual_count" -ne 1 ]; then
      fail "the probe printed ${actual_count} anchored read-back lines for controlled key '${key}' on $absolute_path (expected exactly one) — core ${core_commit}"
    fi

    case "$actual_lines" in
      "readback ${key} ok=0 value="*)
        fail "core ${core_commit} no longer gives controlled key '${key}' a C-readable value (ok=0) for $absolute_path — renamed/aliased or no cval; re-measure and update the waiver ledger on issue #382"
        ;;
      "readback ${key} ok=1 value="*)
        actual_value="${actual_lines#readback ${key} ok=1 value=}"
        ;;
      *)
        fail "the probe printed a malformed anchored read-back line for controlled key '${key}' on $absolute_path: ${actual_lines} — core ${core_commit}"
        ;;
    esac

    if [ -z "$actual_value" ]; then
      fail "the probe printed an empty read-back value for controlled key '${key}' on $absolute_path — core ${core_commit}"
    fi
    if [ "$actual_value" != "$expected_value" ]; then
      fail "core ${core_commit} read back '${key} = ${actual_value}' but $absolute_path emitted '${key} = ${expected_value}' — the key's meaning or tag spelling changed; re-measure and update the waiver ledger on issue #382"
    fi
    printf '  readback %s = %s\n' "$key" "$actual_value"
  done

  # `shell-integration-features` is a u32 bitfield: presence-only (the packed
  # set is not text-derivable). ok must be 1 (issue #382).
  if ! bitfield_expected="$(grep '^shell-integration-features = ' "$absolute_path")"; then
    fail "controlled key 'shell-integration-features' is missing from $absolute_path — the fixture no longer emits it; regenerate the fixture and update the waiver ledger on issue #382 (core ${core_commit})"
  fi
  bitfield_expected_count="$(printf '%s\n' "$bitfield_expected" | grep -c .)"
  if [ "$bitfield_expected_count" -ne 1 ]; then
    fail "controlled key 'shell-integration-features' appears ${bitfield_expected_count} times in $absolute_path (expected exactly one anchored '^shell-integration-features = ' line) — core ${core_commit}"
  fi
  if ! bitfield_lines="$(printf '%s\n' "$probe_output" | grep '^readback shell-integration-features ok=')"; then
    fail "the probe printed no anchored read-back line for controlled key 'shell-integration-features' on $absolute_path — core ${core_commit}"
  fi
  bitfield_count="$(printf '%s\n' "$bitfield_lines" | grep -c .)"
  if [ "$bitfield_count" -ne 1 ]; then
    fail "the probe printed ${bitfield_count} anchored read-back lines for 'shell-integration-features' (expected exactly one) — core ${core_commit}"
  fi
  case "$bitfield_lines" in
    "readback shell-integration-features ok=1 value="*)
      bitfield_value="${bitfield_lines#readback shell-integration-features ok=1 value=}"
      if [ -z "$bitfield_value" ]; then
        fail "the probe printed an empty read-back value for 'shell-integration-features' on $absolute_path — core ${core_commit}"
      fi
      ;;
    "readback shell-integration-features ok=0 value="*)
      fail "core ${core_commit} no longer gives 'shell-integration-features' a C-readable value (ok=0) for $absolute_path; re-measure and update the waiver ledger on issue #382"
      ;;
    *)
      fail "malformed anchored read-back line for 'shell-integration-features': ${bitfield_lines} — core ${core_commit}"
      ;;
  esac
  printf '  readback shell-integration-features = <presence-only>\n'

  # Composed guard (issue #382 plan §3.2): any ok=0 read-back line for a key
  # the fixture emits is a failure, independent of the per-key loop above.
  if unreadable_keys="$(printf '%s\n' "$probe_output" | grep '^readback [a-z0-9-]* ok=0 value=' | sed 's/^readback \([a-z0-9-]*\) ok=0.*$/\1/')"; then
    for key in $unreadable_keys; do
      if grep -q "^${key} = " "$absolute_path"; then
        fail "core ${core_commit} cannot read back emitted key '${key}' (ok=0) for $absolute_path; re-measure and update the waiver ledger on issue #382"
      fi
    done
  fi
done

if [ "$status" -ne 0 ]; then
  printf '\ncheck-ghostty-config: FAILED — the vendored core rejected generated config content\n' >&2
  exit 1
fi

printf 'check-ghostty-config: OK — %d generated config(s) accepted and read back by the vendored core\n' "$#"
