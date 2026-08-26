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

# With a notary profile the app is notarized and stapled before the DMG is
# built, so the copy a person drags out verifies even offline.
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ZIP="$STAGING_DIR/notarize.zip"
  ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$NOTARY_ZIP"
  xcrun stapler staple "$APP_DIR" >/dev/null
  spctl --assess --type execute "$APP_DIR"
  echo "Notarized and stapled $APP_DIR"
fi

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
