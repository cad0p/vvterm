/* SPDX-License-Identifier: MIT */
/*
 * ghostty-config-probe.c — load one Ghostty config through the vendored
 * libghostty, print every diagnostic the core reports for it, then read the
 * controlled keys back through `ghostty_config_get` (issue #382).
 *
 * Used by scripts/ci/check-ghostty-config.sh: VVTerm's generated config must
 * be accepted by the exact core that consumes it, so a key upstream removed
 * (or a value it rejects) fails CI instead of only showing up in the field.
 * The read-back lines let the script assert that the core still applies the
 * fixture's value to a C-readable key, so a silent rename/alias/type change
 * reds CI as well.
 *
 * Usage: ghostty-config-probe <absolute-config-path>
 *
 * Exit codes:
 *   0 — the config loaded with zero diagnostics
 *   1 — at least one diagnostic (each printed to stdout)
 *   2 — usage error or ghostty_init failure
 *
 * The read-back lines are reporters, like the diagnostics: the exit code stays
 * diagnostics-driven and scripts/ci/check-ghostty-config.sh owns the
 * assertion (issue #382).
 *
 * `ghostty_config_get_diagnostic` does not terminate on a NULL message, so
 * the loop is bounded by `ghostty_config_diagnostics_count`.
 *
 * Read-back contract, measured on the vendored core
 * e77b2309fca3a27db1123a4f904b7fb432ee7162 (raw evidence in
 * Build/issue382-evidence/):
 *
 *   - The 4th argument is the KEY LENGTH, not an output size: `font-size`
 *     reads ok=1 at length 9 and ok=0 at lengths 8, 10 and 3.
 *   - On success the core writes the key's NATIVE width into `out` — 4 bytes
 *     for `font-size` (f32; the sink's bytes 4..7 are untouched), 1 byte for
 *     a bool, 8 bytes for an enum tag pointer — regardless of the sink's
 *     type or size. `ok=1` therefore never validates the out pointer: a
 *     mismatched sink silently corrupts memory (measured: `font-size` into a
 *     2-byte sink still returns ok=1 and writes 4 bytes).
 *   - Type table at that commit:
 *       font-size                    f32          -> printed %.9g
 *       window-inherit-font-size     bool         -> printed true/false
 *       cursor-style-blink           ?bool        -> printed true/false
 *       cursor-style                 enum         -> tag-name pointer
 *       window-padding-balance       enum         -> tag-name pointer
 *       window-padding-color         enum         -> tag-name pointer
 *       clipboard-read               enum         -> tag-name pointer
 *       shell-integration            enum         -> tag-name pointer
 *       macos-option-as-alt          enum         -> tag-name pointer
 *       shell-integration-features   u32 bitfield -> printed presence-only
 *   - `ok=0` means the key is no longer C-readable: renamed/aliased or its
 *     type has no cval. It does not distinguish alias from absent
 *     (`background-blur-radius` ok=0 / `background-blur` ok=1;
 *     `scrollback-limit` ok=0).
 *   - `Limit`/struct/list-typed keys are unreadable at every sink:
 *     `font-family` (list), `window-padding-x` / `window-padding-y`
 *     (`WindowPadding` structs), `theme`, `scrollback-limit-lines` (`Limit`),
 *     `mouse-scroll-multiplier` (struct), `keybind` (list).
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ghostty.h"

static void print_unreadable(const char *key) {
    printf("readback %s ok=0 value=<unreadable>\n", key);
}

static void readback_float(ghostty_config_t config, const char *key) {
    /* A float sink NaN-initialised so an unwritten or wrongly-sized write is
     * visible in the printed value instead of silently equal. */
    float sink = NAN;
    if (!ghostty_config_get(config, &sink, key, (uintptr_t)strlen(key))) {
        print_unreadable(key);
        return;
    }
    printf("readback %s ok=1 value=%.9g\n", key, (double)sink);
}

static void readback_bool(ghostty_config_t config, const char *key) {
    /* -1 is the untouched sentinel: a bool write is exactly one byte. */
    int8_t sink = -1;
    if (!ghostty_config_get(config, &sink, key, (uintptr_t)strlen(key))) {
        print_unreadable(key);
        return;
    }
    if (sink == 0) {
        printf("readback %s ok=1 value=false\n", key);
    } else if (sink == 1) {
        printf("readback %s ok=1 value=true\n", key);
    } else {
        printf("readback %s ok=1 value=<sentinel:%d>\n", key, (int)sink);
    }
}

static void readback_enum(ghostty_config_t config, const char *key) {
    /* Enum values come back as a pointer to the core's tag-name string.
     * 0x1 is the untouched sentinel; NULL and plausible-looking low values
     * are reported as sentinels. This guard cannot prove pointer validity: a
     * wrong-width write can still land an address the probe dereferences;
     * the script reds either way. */
    const char *sink = (const char *)0x1;
    if (!ghostty_config_get(config, &sink, key, (uintptr_t)strlen(key))) {
        print_unreadable(key);
        return;
    }
    if (sink == NULL || (uintptr_t)sink < 0x10000) {
        printf("readback %s ok=1 value=<sentinel>\n", key);
        return;
    }
    printf("readback %s ok=1 value=%s\n", key, sink);
}

static void readback_bitfield(ghostty_config_t config, const char *key) {
    /* The packed feature set is a u32 in a zeroed 8-byte sink. It is not
     * text-derivable, so the script asserts presence (ok=1) only. */
    unsigned char sink[8] = {0};
    if (!ghostty_config_get(config, sink, key, (uintptr_t)strlen(key))) {
        print_unreadable(key);
        return;
    }
    uint32_t value = 0;
    memcpy(&value, sink, sizeof(value));
    printf("readback %s ok=1 value=<bitfield:%u>\n", key, value);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <absolute-config-path>\n", argv[0]);
        return 2;
    }

    int init_result = ghostty_init((uintptr_t)argc, argv);
    if (init_result != 0) {
        fprintf(stderr, "ghostty_init failed with code %d\n", init_result);
        return 2;
    }

    ghostty_config_t config = ghostty_config_new();
    if (config == NULL) {
        fprintf(stderr, "ghostty_config_new returned NULL\n");
        return 2;
    }

    ghostty_config_load_file(config, argv[1]);
    ghostty_config_finalize(config);

    uint32_t count = ghostty_config_diagnostics_count(config);
    for (uint32_t i = 0; i < count; i++) {
        ghostty_diagnostic_s diagnostic = ghostty_config_get_diagnostic(config, i);
        printf("%s\n", diagnostic.message == NULL ? "<null diagnostic message>" : diagnostic.message);
    }

    /* The controlled keys (issue #382). Every emitted key must appear here
     * and in the script's assertion loop; the source-containment pin keeps
     * the two lists in sync. */
    readback_float(config, "font-size");
    readback_bool(config, "window-inherit-font-size");
    readback_bool(config, "cursor-style-blink");
    readback_enum(config, "cursor-style");
    readback_enum(config, "window-padding-balance");
    readback_enum(config, "window-padding-color");
    readback_enum(config, "clipboard-read");
    readback_enum(config, "shell-integration");
    readback_enum(config, "macos-option-as-alt");
    readback_bitfield(config, "shell-integration-features");

    ghostty_config_free(config);

    return count == 0 ? 0 : 1;
}
