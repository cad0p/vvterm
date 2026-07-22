#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Regenerate the Swift-test fixtures.
#
# The fixture generator (fixtures/generate/main.go) is self-contained: it
# inlines the one Teleport function it needed (ecdsaPublicKeyFromRaw, a
# 45-line stdlib-only copy of lib/darwin.ECDSAPublicKeyFromRaw) so it doesn't
# pull the entire teleport module (which requires Go >= 1.25.11 and has a
# complex nested api module). The generator depends only on fxamacker/cbor
# (the same CBOR lib Teleport uses) + the Go stdlib.
#
# Requires: Go 1.21+ (any recent version).
#
# Usage:
#   ./regenerate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go not installed. Install from https://go.dev/dl/" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"

# Minimal go.mod that imports only fxamacker/cbor + google/uuid + stdlib.
# The generators inline the one or two Teleport functions they need
# (ecdsaPublicKeyFromRaw, NewHeadlessAuthenticationID) to avoid pulling
# the entire teleport module into the dep graph — teleport v18.9.1
# requires Go >= 1.25.11 and its nested api module has complex resolution.
# By inlining, the fixture generators are self-contained.
cat > go.mod <<EOF
module sep-webauthn-fixture-gen

go 1.21

require (
	github.com/fxamacker/cbor/v2 v2.5.0
	github.com/google/uuid v1.6.0
)
EOF

# Copy the fixture generators into the work module.
mkdir -p gen
cp "$SCRIPT_DIR/generate/main.go" gen/main.go
mkdir -p gen/headless
cp "$SCRIPT_DIR/generate/headless/main.go" gen/headless/main.go

# Download fxamacker/cbor (the only external dep — the teleport replace
# brings the rest in-tree).
echo "→ go mod tidy"
go mod tidy 2>&1 | sed 's/^/  /' || true

echo "→ go run ./gen"
go run ./gen

echo "→ go run ./gen/headless"
go run ./gen/headless

# The generator writes to fixtures/expected/ relative to its working dir,
# which is $WORKDIR. Copy the output back to the package.
echo "→ copying fixtures back to $PKG_DIR/fixtures/expected/"
mkdir -p "$PKG_DIR/fixtures/expected"
cp -v "$WORKDIR"/fixtures/expected/* "$PKG_DIR/fixtures/expected/"

echo
echo "✓ fixtures regenerated. Commit the changes in fixtures/expected/."
