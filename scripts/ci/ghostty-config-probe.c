/* SPDX-License-Identifier: MIT */
/*
 * ghostty-config-probe.c — load one Ghostty config through the vendored
 * libghostty and print every diagnostic the core reports for it.
 *
 * Used by scripts/ci/check-ghostty-config.sh: VVTerm's generated config must
 * be accepted by the exact core that consumes it, so a key upstream removed
 * (or a value it rejects) fails CI instead of only showing up in the field.
 *
 * Usage: ghostty-config-probe <absolute-config-path>
 *
 * Exit codes:
 *   0 — the config loaded with zero diagnostics
 *   1 — at least one diagnostic (each printed to stdout)
 *   2 — usage error or ghostty_init failure
 *
 * `ghostty_config_get_diagnostic` does not terminate on a NULL message, so
 * the loop is bounded by `ghostty_config_diagnostics_count`.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ghostty.h"

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

    ghostty_config_free(config);

    return count == 0 ? 0 : 1;
}
