#!/bin/sh
# Builds with SwiftPM and assembles a signed ServerLife.app.
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
#
# VERSION holds the marketing version (kept in step with the Electron app it
# ports); BUILD_NUMBER is bumped on every successful build.
set -eu
cd "$(dirname "$0")/.."
CONF="${1:-release}"
APP="build/ServerLife.app"
ICON_PNG="Resources/appicon.png"
mkdir -p build

if ! swift build -c "$CONF" > build/swift-build.log 2>&1; then
  grep -E 'error' build/swift-build.log | grep -v '^\s*|' | sed 's/\x1b\[[0-9;]*m//g' | sort -u >&2 || cat build/swift-build.log >&2
  echo "build failed; see build/swift-build.log" >&2
  exit 1
fi
BIN_DIR="$(swift build -c "$CONF" --show-bin-path)"
BIN="$BIN_DIR/ServerLife"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

VERSION="$(tr -d ' \n' < VERSION 2>/dev/null || true)"; [ -n "$VERSION" ] || VERSION="0.0.0"
BUILD="$(tr -d ' \n' < BUILD_NUMBER 2>/dev/null || true)"
case "$BUILD" in ''|*[!0-9]*) BUILD=0 ;; esac
BUILD=$((BUILD + 1)); echo "$BUILD" > BUILD_NUMBER

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ServerLife"
# Docs and assets the app reads at runtime (guide, changelog, MCP notes).
for f in Resources/*; do
  case "$f" in *.svg|*appicon.png) ;; *) cp -R "$f" "$APP/Contents/Resources/" ;; esac
done

if [ -f "$ICON_PNG" ]; then
  ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ServerLife</string>
  <key>CFBundleDisplayName</key><string>ServerLife</string>
  <key>CFBundleIdentifier</key><string>dev.serverlife.swift</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>ServerLife</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Network tools fetch whatever URL is asked for, plain http and old TLS
       included, as the Electron app did; ATS would refuse them. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ServerLife opens Remote Desktop and Terminal on your behalf when you ask it to.</string>
  <key>NSLocalNetworkUsageDescription</key><string>ServerLife connects to servers, consoles and screens on your network.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP — version $VERSION ($BUILD)"
