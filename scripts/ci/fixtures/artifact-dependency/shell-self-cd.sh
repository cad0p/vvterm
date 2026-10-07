#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399 fold round 2, N7): the self-reference precedes this script's
# own `cd`, so the cwd test must stay order-aware; the visited set cuts the
# self-delegation recursion.
set -euo pipefail
SELF="scripts/ci/shell-self-cd.sh"
cd "$(dirname "$0")"
echo "self-cd benign"
