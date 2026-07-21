#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regenerate the Swift-test fixtures from Teleport's lib/auth/touchid/api.go.
#
# Requires Go (any recent version) and the Teleport source tree checked out
# at $TELEPORT_SRC (default: ~/open-source/github/cad0p/teleport, pinned v18.9.1).
#
# Usage:
#   ./regenerate.sh                    # uses default TELEPORT_SRC
#   TELEPORT_SRC=/path/to/teleport ./regenerate.sh
#
# This script creates a temporary Go module that imports the vendored
# Teleport packages via a `replace` directive, so the fixture generator
# resolves `github.com/gravitational/teleport/lib/...` against the local
# checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TELEPORT_SRC="${TELEPORT_SRC:-$HOME/open-source/github/cad0p/teleport}"

if [[ ! -d "$TELEPORT_SRC" ]]; then
    echo "ERROR: TELEPORT_SRC not found: $TELEPORT_SRC" >&2
    echo "Clone teleport at v18.9.1 or set TELEPORT_SRC=/path/to/teleport" >&2
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go not installed. Install from https://go.dev/dl/" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"

# Minimal go.mod that imports fxamacker/cbor (the same lib Teleport uses) and
# replaces the teleport module with the local checkout.
cat > go.mod <<EOF
module sep-webauthn-fixture-gen

go 1.21

require (
    github.com/fxamacker/cbor/v2 v2.5.0
    github.com/gravitational/teleport v0.0.0
)

replace github.com/gravitational/teleport => $TELEPORT_SRC
EOF

# Copy the fixture generator into the work module.
mkdir -p gen
cp "$SCRIPT_DIR/generate/main.go" gen/main.go

# Download fxamacker/cbor (the only external dep — the teleport replace
# brings the rest in-tree).
echo "→ go mod tidy"
go mod tidy 2>&1 | sed 's/^/  /' || true

echo "→ go run ./gen"
go run ./gen

# The generator writes to fixtures/expected/ relative to its working dir,
# which is $WORKDIR. Copy the output back to the package.
echo "→ copying fixtures back to $PKG_DIR/fixtures/expected/"
mkdir -p "$PKG_DIR/fixtures/expected"
cp -v "$WORKDIR"/fixtures/expected/* "$PKG_DIR/fixtures/expected/"

echo
echo "✓ fixtures regenerated. Commit the changes in fixtures/expected/."
