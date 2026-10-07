#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): the a -> b half of the benign delegation cycle; the visited
# set cuts the b -> a reference on the second pass.
set -euo pipefail
bash scripts/ci/shell-cycle-b.sh
