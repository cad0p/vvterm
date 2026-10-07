#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): hop 4 of the depth-cap reject chain; this delegation is the
# one the cap refuses (the refusal names this line).
set -euo pipefail
bash scripts/ci/shell-chain-5.sh
