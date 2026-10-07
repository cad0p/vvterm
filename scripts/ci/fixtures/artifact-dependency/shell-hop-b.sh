#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): the second hop of the transitive-delegation reject; the
# `gh -R owner/repo run download` spelling exercises branch A with an operand
# between `gh` and the `run download` pair.
set -euo pipefail
gh -R owner/repo run download 12345 -n vvterm-build
