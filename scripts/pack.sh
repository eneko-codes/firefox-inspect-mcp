#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. zip is enough, so the toolchain stays
# what macOS ships.
set -euo pipefail

NAME="firefox-inspect-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Apple silicon only: a plain `swift build -c release`, no --arch flags.
echo "==> Building $NAME (arm64)"
swift build -c release

BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

ARCHS="$(lipo -archs "$BINARY")"
[ "$ARCHS" = "arm64" ] || { echo "!! expected arm64 only, got: $ARCHS" >&2; exit 1; }

python3 -c "import json; json.load(open('extension/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# Ad-hoc signature with a fixed identifier. Nothing here is TCC-gated, so no real
# identity is needed; this only replaces the linker's signature with a proper one.
codesign --force --identifier "codes.eneko.$NAME" --sign - "$STAGE/server/$NAME"

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude."
