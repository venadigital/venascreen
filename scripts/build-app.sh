#!/bin/bash
# Builds VenaScreen.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/VenaScreen.app"
VERSION="1.0.0"

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! swift build -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then swift build -c "$CONFIG" --triple "$triple" >&2; fi
  cp "$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/VenaScreen" "$OUT/VenaScreen-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
build_arch arm64
build_arch x86_64
lipo -create "$OUT/VenaScreen-arm64" "$OUT/VenaScreen-x86_64" -output "$OUT/VenaScreen"
BIN="$OUT/VenaScreen"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VenaScreen"

# Icon
WORK="$(mktemp -d)"
sips -z 1024 1024 Assets/logo.png --out "$WORK/icon.png" >/dev/null
ICONSET="$WORK/VenaScreen.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/VenaScreen.icns"
# Menu bar icon: the logo at 1x and 2x.
sips -z 18 18 Assets/menubar-face.png --out "$APP/Contents/Resources/menubar.png" >/dev/null
sips -z 36 36 Assets/menubar-face.png --out "$APP/Contents/Resources/menubar@2x.png" >/dev/null
rm -rf "$WORK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VenaScreen</string>
  <key>CFBundleDisplayName</key><string>VenaScreen</string>
  <key>CFBundleIdentifier</key><string>com.venadigital.VenaScreen</string>
  <key>CFBundleExecutable</key><string>VenaScreen</string>
  <key>CFBundleIconFile</key><string>VenaScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>VenaScreen watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>VenaScreen takes your screenshots and hangs them on the line.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>VenaScreen watches your Downloads folder for new images so it can hang them on the line.</string>
</dict>
</plist>
PLIST

# Sign with the "VenaScreen Dev" certificate when it is in the keychain. A
# stable signature lets macOS remember Screen Recording and folder access
# across rebuilds. Without it, fall back to an ad-hoc signature, and macOS
# asks for those permissions again after every build.
IDENTITY="${SIGN_IDENTITY:-VenaScreen Dev}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null
  echo "Signed with $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad hoc (no \"$IDENTITY\" certificate found)"
fi
echo "Built $APP"
