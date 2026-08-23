#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/iLabel Studio.app"
DMG_PATH="$ROOT_DIR/dist/iLabel-Studio-macOS.dmg"
VOL_NAME="iLabel Studio"
STAGING_DIR="$(mktemp -d /tmp/iLabel-Studio-dmg.XXXXXX)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build_app.sh"

mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH" >/dev/null

echo "Built $DMG_PATH"
