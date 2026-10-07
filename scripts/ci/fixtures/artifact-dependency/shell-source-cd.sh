#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399 fold round 3, N13): the sourced helper's `cd` propagates into
# the sourcing shell, so the caller's later delegation is refused.
set -euo pipefail
cd sub
