#!/bin/bash
# Builds a real, launchable Teleport Connect Native.app — release binary + resource bundle +
# .icns (regenerated from AppIconSource/icon-preview.svg) + Info.plist, ad-hoc signed.
#
# No Xcode required: qlmanage/sips/iconutil/codesign all ship with the base OS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Teleport Connect Native"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ICON_SRC="$ROOT/AppIconSource"

echo "==> Building release binary"
swift build -c release --product TeleportConnectNative

BUILT_DIR="$(swift build -c release --show-bin-path)"
# SwiftPM's build description dir can differ from --show-bin-path on some setups; fall back to
# the known Products/Release location used by this checkout's custom build path.
if [ ! -f "$BUILT_DIR/TeleportConnectNative" ]; then
    BUILT_DIR=".build/out/Products/Release"
fi

echo "==> Rendering app icon from $ICON_SRC/icon-preview.svg"
rm -rf "$ICON_SRC/render" "$ICON_SRC/AppIcon.iconset"
mkdir -p "$ICON_SRC/render" "$ICON_SRC/AppIcon.iconset"
qlmanage -t -s 1024 -o "$ICON_SRC/render" "$ICON_SRC/icon-preview.svg" >/dev/null
SRC_PNG="$ICON_SRC/render/icon-preview.svg.png"

sips -z 16 16     "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32     "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64     "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256   "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512   "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC_PNG" --out "$ICON_SRC/AppIcon.iconset/icon_512x512.png" >/dev/null
cp "$SRC_PNG" "$ICON_SRC/AppIcon.iconset/icon_512x512@2x.png"
iconutil -c icns "$ICON_SRC/AppIcon.iconset" -o "$ICON_SRC/AppIcon.icns"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT_DIR/TeleportConnectNative" "$APP/Contents/MacOS/TeleportConnectNative"
cp -R "$BUILT_DIR/TeleportConnectNative_TeleportConnectNative.bundle" "$APP/Contents/Resources/"
cp "$ICON_SRC/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "Run it with: open \"$APP\""
