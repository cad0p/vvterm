#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fixture (#399): a delegated script that runs the shell artifact downloader
# the gate refuses; shared by the three delegation-reject workflows.
set -euo pipefail
gh run download 12345 -n vvterm-build
