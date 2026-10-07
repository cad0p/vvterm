#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): a benign delegated script. The `gh run download` mention in
# this comment is text, and the self-reference in the echo word below resolves
# to this same file, so the visited set cuts the recursion.
set -euo pipefail
echo "scripts/ci/shell-benign.sh is the delegated target"
