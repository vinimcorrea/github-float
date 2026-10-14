#!/bin/bash
# Builds GitHubFloat.app.
#   ./build.sh          build and install into ~/Applications
#   ./build.sh --dist   build a universal (arm64 + x86_64) app into dist/ and zip it for a release
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

if [ "${1:-}" = "--dist" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/GitHubFloat"
  APP="dist/GitHubFloat.app"
  mkdir -p dist
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/GitHubFloat"
  APP="$HOME/Applications/GitHubFloat.app"
  mkdir -p "$HOME/Applications"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitHubFloat"
"$BIN" --render-sounds "$APP/Contents/Resources"

# App icon: render the PNG (if missing) and convert it into an .icns.
[ -f Icon/AppIcon.png ] || swift Icon/make_icon.swift Icon/AppIcon.png
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Icon/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ICONSET/icon_128x128@2x.png" "$APP/Contents/Resources/NotificationIcon.png"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GitHubFloat</string>
  <key>CFBundleDisplayName</key><string>GitHub Float</string>
  <key>CFBundleIdentifier</key><string>com.vinimcorrea.githubfloat</string>
  <key>CFBundleExecutable</key><string>GitHubFloat</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--dist" ]; then
  (cd dist && rm -f GitHubFloat.zip && ditto -c -k --keepParent GitHubFloat.app GitHubFloat.zip)
  shasum -a 256 dist/GitHubFloat.zip
  echo "Built dist/GitHubFloat.zip (v${VERSION})"
else
  echo "Installed $APP (v${VERSION})"
fi
