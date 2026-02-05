#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_ICON="${STASH_ICON_SOURCE:-$ROOT_DIR/frontend-macos/Resources/AppIcon-source.png}"
ICONSET_DIR="${STASH_ICONSET_DIR:-$ROOT_DIR/frontend-macos/Resources/AppIcon.iconset}"
ICNS_OUT="${STASH_ICNS_OUT:-$ROOT_DIR/frontend-macos/Resources/AppIcon.icns}"

if [ ! -f "$SOURCE_ICON" ]; then
  echo "Icon source image not found: $SOURCE_ICON" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "sips command is required" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "iconutil command is required" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"
rm -f "$ICONSET_DIR"/*.png

# Build a square master image for deterministic downscaling.
MASTER="$ICONSET_DIR/icon-master.png"
sips --cropToHeightWidth 1024 1024 "$SOURCE_ICON" --out "$MASTER" >/dev/null

make_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET_DIR/$name" >/dev/null
}

make_icon 16  "icon_16x16.png"
make_icon 32  "icon_16x16@2x.png"
make_icon 32  "icon_32x32.png"
make_icon 64  "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"

echo "Generated: $ICNS_OUT"
