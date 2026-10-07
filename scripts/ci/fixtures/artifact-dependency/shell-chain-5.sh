#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): the fifth hop of the depth-cap reject chain is benign, so
# only the nested-delegation analysis bound refuses the chain; without the
# cap the whole chain scans clean.
set -euo pipefail
echo "chain end"
