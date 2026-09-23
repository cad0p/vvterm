#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Regenerate VVTerm/Features/Teleport/Infrastructure/iotest_mfa.pb.swift from
# the hand-authored iotest_mfa.proto.
#
# Pinned toolchain (the generated Swift must be produced by these versions so
# the output is reproducible):
#   - protoc           36.2
#   - protoc-gen-swift 1.38.1 (swift-protobuf 1.38.1, the version the app and
#     the future swift-teleport package resolve)
#
# The script:
#   1. generates with Visibility=Public so the Proto_* types can cross the
#      swift-teleport module boundary in Stage B (the host is unaffected by
#      the wider access);
#   2. normalizes the `nonisolated` modifiers on every generated type, enum,
#      and the file-private package constant. The future package builds with
#      `.defaultIsolation(MainActor.self)`; without the modifiers the
#      generated declarations are MainActor-isolated and the movable set
#      fails to compile (see the Phase 1b plan, B3). protoc-gen-swift 1.38.1
#      already emits the modifiers — the normalization is idempotent and
#      keeps an older generator from silently dropping them;
#   3. verifies the MIT SPDX header (copied from the .proto's leading
#      comments) and the expected declaration counts, so a regeneration that
#      changes the schema shape fails loudly instead of drifting silently.
#
# Requires: protoc + protoc-gen-swift on PATH (brew install protobuf
# swift-protobuf).
#
# Usage:
#   ./scripts/regen-iotest-mfa.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PROTO_DIR="VVTerm/Features/Teleport/Infrastructure"
PROTO="$PROTO_DIR/iotest_mfa.proto"
PB="$PROTO_DIR/iotest_mfa.pb.swift"

if ! command -v protoc >/dev/null 2>&1; then
  echo "ERROR: protoc not found. Install with: brew install protobuf" >&2
  exit 1
fi
if ! command -v protoc-gen-swift >/dev/null 2>&1; then
  echo "ERROR: protoc-gen-swift not found. Install with: brew install swift-protobuf" >&2
  exit 1
fi

protoc_version="$(protoc --version)"
plugin_version="$(protoc-gen-swift --version)"
case "$protoc_version" in
  "libprotoc 36.2"*) ;;
  *) echo "ERROR: protoc 36.2 required, found: $protoc_version" >&2; exit 1 ;;
esac
case "$plugin_version" in
  "protoc-gen-swift 1.38.1"*) ;;
  *) echo "ERROR: protoc-gen-swift 1.38.1 required, found: $plugin_version" >&2; exit 1 ;;
esac

protoc \
  --proto_path="$PROTO_DIR" \
  --swift_out="$PROTO_DIR" \
  --swift_opt=Visibility=Public \
  "$PROTO"

# Idempotent nonisolated normalization (see the header). The patterns match
# the unmodified generator output; already-normalized lines are untouched.
perl -0pi -e '
  s/^public struct (Proto_[A-Za-z0-9_]+)/public nonisolated struct $1/gm;
  s/^public enum (Proto_[A-Za-z0-9_]+)/public nonisolated enum $1/gm;
  s/^fileprivate let _protobuf_package/fileprivate nonisolated let _protobuf_package/gm;
' "$PB"

# The generator copies the .proto's leading comments into the Swift file, so
# the MIT SPDX header rides along. Assert it, plus the schema shape, so a
# schema change or a generator swap cannot pass silently.
grep -q '^// SPDX-License-Identifier: MIT$' "$PB" || {
  echo "ERROR: $PB is missing the MIT SPDX header" >&2
  exit 1
}
structs="$(grep -c '^public nonisolated struct Proto_' "$PB")"
enums="$(grep -c '^public nonisolated enum Proto_' "$PB")"
package_consts="$(grep -c '^fileprivate nonisolated let _protobuf_package' "$PB")"
if [ "$structs" -ne 26 ] || [ "$enums" -ne 3 ] || [ "$package_consts" -ne 1 ]; then
  echo "ERROR: unexpected generated shape: structs=$structs (want 26), enums=$enums (want 3), _protobuf_package=$package_consts (want 1)" >&2
  exit 1
fi

echo "regenerated $PB (protoc 36.2, protoc-gen-swift 1.38.1; $structs structs, $enums enums)"
