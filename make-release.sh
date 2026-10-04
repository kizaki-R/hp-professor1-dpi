#!/bin/bash
# Builds the release artefacts for GitHub Releases.
#
#   dist/DPIPeek-<version>.zip        the signed .app (users unzip into /Applications)
#   dist/hp-professor1-dpi-<version>-src.tar.gz  source tarball without the local signing identity
#
# The app is signed with the local self-signed identity (KizakiWorks Local) when it exists.
# That is fine for local builds, but a downloaded zip is quarantined by macOS — tell users to
# right-click → Open, or notarize with an Apple Developer ID if you have one.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" src/Info.plist 2>/dev/null || echo 1.0)
NAME="DPIPeek-$VERSION"
DIST="dist"

echo "==> building"
./build.sh

mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/hp-professor1-dpi-$VERSION-src.tar.gz"

echo "==> packaging $NAME.zip"
# ditto keeps the bundle metadata intact (plain zip can break .app bundles)
ditto -c -k --sequesterRsrc --keepParent DPIPeek.app "$DIST/$NAME.zip"

echo "==> packaging source"
tar --exclude='./dist' --exclude='./build' --exclude='./logs' --exclude='./signing' \
    --exclude='./DPIPeek.app' --exclude='./probe' --exclude='./royuan' \
    --exclude='.DS_Store' -czf "$DIST/hp-professor1-dpi-$VERSION-src.tar.gz" .

echo
echo "==> artefacts"
ls -lh "$DIST"
echo
echo "sha256:"
shasum -a 256 "$DIST"/*
echo
echo "上傳到 GitHub Releases 後，記得在 README 提醒使用者：第一次開啟要「右鍵 → 打開」。"
