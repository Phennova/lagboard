#!/bin/zsh
# Builds LagBoard.app next to this script.
#
# The app is assembled and signed in a temp folder first: iCloud-synced folders (like
# Desktop/Documents) attach Finder metadata to bundles, which breaks code signing.
set -euo pipefail
cd "$(dirname "$0")"

STAGE="${TMPDIR:-/tmp}/lagboard-build"
APP="$STAGE/LagBoard.app"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework Network -framework Carbon -framework AVFoundation -framework CoreMediaIO -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  Sources/*.swift -o "$APP/Contents/MacOS/LagBoard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LagBoard</string>
  <key>CFBundleDisplayName</key><string>LagBoard</string>
  <key>CFBundleIdentifier</key><string>local.lagboard.app</string>
  <key>CFBundleExecutable</key><string>LagBoard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>LagBoard reads your camera so it can add fake bad-connection effects and send it out through the virtual camera.</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp -R ../extension "$APP/Contents/Resources/extension"

xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# Local copy for running from the project folder.
rm -rf LagBoard.app
ditto --norsrc --noextattr "$APP" LagBoard.app
echo "Built $(pwd)/LagBoard.app (signed copy: $APP)"
