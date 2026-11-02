#!/bin/zsh
# Builds LagBoard.app and zips it into dist/ for a GitHub release.
#   ./release.sh 1.0.1            Apple Silicon
#   ./release.sh 1.0.1 x86_64     Intel
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: release.sh <version> [arm64|x86_64]}"
ARCH="${2:-arm64}"
VERSION="$VERSION" ARCH="$ARCH" ./build.sh

APP="${TMPDIR:-/tmp}/lagboard-build-$ARCH/LagBoard.app"  # clean, signed build from build.sh
codesign --verify --deep --strict "$APP"
archs=$(lipo -archs "$APP/Contents/MacOS/LagBoard")
[[ "$archs" == "$ARCH" ]] || { echo "unexpected architectures: $archs"; exit 1; }

mkdir -p ../dist
ZIP="../dist/LagBoard-${VERSION}-macOS-${ARCH}.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
echo "Packaged $(cd ../dist && pwd)/$(basename "$ZIP") ($archs)"
