#!/usr/bin/env bash
# Regenerates all app icon assets from the vector source Resources/AppIcon.svg.
# Requires: librsvg (brew install librsvg), imagemagick (brew install imagemagick).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT_DIR/Resources/AppIcon.svg"
ICONSET="$ROOT_DIR/Resources/AppIcon.iconset"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$ICONSET"

while read -r size name; do
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/$name.png"
done <<'EOF'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
EOF

iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Resources/AppIcon.icns"

for size in 16 24 32 48 64 128 256; do
  rsvg-convert -w "$size" -h "$size" "$SVG" -o "$TMP_DIR/ico_$size.png"
done
magick "$TMP_DIR"/ico_{16,24,32,48,64,128,256}.png "$ROOT_DIR/Resources/AppIcon.ico"

echo "Regenerated AppIcon.iconset, AppIcon.icns, AppIcon.ico from AppIcon.svg"
