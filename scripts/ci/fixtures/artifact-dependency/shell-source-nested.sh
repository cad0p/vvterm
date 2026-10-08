#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#403, N18): the nested source hop; helper.sh's `cd` propagates
# through this script into the sourcing shell.
set -euo pipefail
. scripts/ci/helper.sh
