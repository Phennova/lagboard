#!/bin/zsh
# Builds LagBoard.app for Apple Silicon and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
./build.sh

archs=$(lipo -archs LagBoard.app/Contents/MacOS/LagBoard)
[[ "$archs" == "arm64" ]] || { echo "unexpected architectures: $archs"; exit 1; }

mkdir -p ../dist
ZIP="../dist/LagBoard-${VERSION}-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent LagBoard.app "$ZIP"
echo "Packaged $(cd ../dist && pwd)/$(basename "$ZIP") ($archs)"
