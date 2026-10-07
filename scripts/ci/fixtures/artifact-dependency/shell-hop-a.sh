#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): the first hop of the transitive-delegation reject; the
# downloader lives two delegations deep, in shell-hop-b.sh.
set -euo pipefail
bash scripts/ci/shell-hop-b.sh
