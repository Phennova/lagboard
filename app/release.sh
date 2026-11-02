#!/bin/zsh
# Builds LagBoard.app for Apple Silicon and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh <version>}"
VERSION="$VERSION" ./build.sh

APP="${TMPDIR:-/tmp}/lagboard-build/LagBoard.app"  # clean, signed build from build.sh
codesign --verify --deep --strict "$APP"
archs=$(lipo -archs "$APP/Contents/MacOS/LagBoard")
[[ "$archs" == "arm64" ]] || { echo "unexpected architectures: $archs"; exit 1; }

mkdir -p ../dist
ZIP="../dist/LagBoard-${VERSION}-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "Packaged $(cd ../dist && pwd)/$(basename "$ZIP") ($archs)"
