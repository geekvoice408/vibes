#!/bin/sh
# Builds "eero Desktop.app" from the Swift package. Usage: Scripts/make-app.sh [output-dir]
# Set SIGN_IDENTITY (and TEAM_ID for the network-extension entitlement) to sign with a developer certificate;
# otherwise the app is ad-hoc signed without the network-extension entitlement.
# Builds for this Mac's architecture. Set UNIVERSAL=1 for an arm64 + x86_64 app (needs full Xcode, not just
# the Command Line Tools, because SwiftPM uses XCBuild for multi-architecture builds).
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-build}"
APP="$OUT/eero Desktop.app"
if [ "${UNIVERSAL:-0}" = 1 ]; then
  set -- -c release --arch arm64 --arch x86_64
else
  set -- -c release
fi
swift build "$@"
BIN="$(swift build "$@" --show-bin-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EeroDesktop" "$APP/Contents/MacOS/EeroDesktop"
cp -R "$BIN/EeroDesktop_EeroDesktop.bundle" "$APP/Contents/Resources/"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Sources/EeroDesktop/Resources/app-icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z $d $d Sources/EeroDesktop/Resources/app-icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
ENT="Bundle/EeroDesktop.entitlements"
if [ -z "${TEAM_ID:-}" ]; then
  ENT="$OUT/adhoc.entitlements"
  cp Bundle/EeroDesktop.entitlements "$ENT"
  /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.networking.networkextension" "$ENT"
fi
codesign --force --deep --options runtime --entitlements "$ENT" --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
