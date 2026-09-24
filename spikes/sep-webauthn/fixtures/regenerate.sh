#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
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
#   ./regenerate.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to fixtures/expected/ next to this script. The
# provenance check (check-provenance.sh) passes a temp dir so it can compare
# without touching the committed tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$PKG_DIR/fixtures/expected}"

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go not installed. Install from https://go.dev/dl/" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$WORKDIR"

# Minimal go.mod that imports only fxamacker/cbor + stdlib. The generator
# inlines the one Teleport function it needed (ecdsaPublicKeyFromRaw, a 45-line
# stdlib-only parser) to avoid pulling the entire teleport module into the dep
# graph — teleport v18.9.1 requires Go >= 1.25.11 and its nested api module has
# complex resolution. By inlining, the fixture generator is self-contained.
cat > go.mod <<EOF
module sep-webauthn-fixture-gen

go 1.21

require github.com/fxamacker/cbor/v2 v2.5.0
EOF

# Copy the fixture generator into the work module.
mkdir -p gen
cp "$SCRIPT_DIR/generate/main.go" gen/main.go

# Download fxamacker/cbor (the only external dep; the generator is
# self-contained and brings nothing else in-tree).
echo "→ go mod tidy"
go mod tidy 2>&1 | sed 's/^/  /' || true

echo "→ go run ./gen"
go run ./gen

# The generator writes to fixtures/expected/ relative to its working dir,
# which is $WORKDIR. Copy the output to OUT_DIR.
echo "→ copying fixtures to $OUT_DIR/"
mkdir -p "$OUT_DIR"
cp -v "$WORKDIR"/fixtures/expected/* "$OUT_DIR/"

echo
echo "✓ fixtures regenerated in $OUT_DIR."
