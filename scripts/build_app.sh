#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/iLabel2Mac.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
# Universal (arm64 + x86_64) binary so the app runs on both Apple Silicon and Intel Macs.
BUILD_BIN="$ROOT_DIR/.build/apple/Products/Release/iLabel2Mac"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_BIN" "$MACOS_DIR/iLabel2Mac"
chmod +x "$MACOS_DIR/iLabel2Mac"
lipo -archs "$MACOS_DIR/iLabel2Mac"
if [ -f "$ROOT_DIR/Resources/official_formats.json" ]; then
  cp "$ROOT_DIR/Resources/official_formats.json" "$RESOURCES_DIR/official_formats.json"
fi
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>iLabel2Mac</string>
    <key>CFBundleDisplayName</key>
    <string>iLabel2Mac</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.jaeyoon.iLabel2Mac</string>
    <key>CFBundleGetInfoString</key>
    <string>iLabel2Mac by Jae-Yoon Sung</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>iLabel2Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Jae-Yoon Sung</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
