#!/bin/bash
# Builds DPI Peek.app and the diagnostic CLI (probe).
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/HP Professor 1 DPI.app"
CACHE="build.noindex/mcache"
mkdir -p build "$CACHE"

echo "==> compiling HPProfessor1DPI binary"
clang -fobjc-arc -fmodules-cache-path="$CACHE" -O2 -Wall \
    -o build/HPProfessor1DPI \
    src/DPIPeek.m src/HIDWatcher.m src/DPIMapper.m src/VendorChannel.m src/BLEBatteryReader.m src/Localization.m \
    -framework Cocoa -framework IOKit -framework CoreBluetooth

echo "==> compiling probe CLI"
clang -fobjc-arc -fmodules-cache-path="$CACHE" -O2 \
    -o probe src/probe.m -framework Foundation -framework IOKit

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp src/Info.plist "$APP/Contents/Info.plist"
cp build/HPProfessor1DPI "$APP/Contents/MacOS/HPProfessor1DPI"
if [ -f src/AppIcon.icns ]; then
    cp src/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -d src/Resources ]; then
    cp -R src/Resources/* "$APP/Contents/Resources/"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with the stable local identity when it exists (run ./make-identity.sh once):
# TCC keys "輸入監控" permission on the signature, so a stable identity means you only
# have to grant it once instead of after every rebuild.
KC="$(pwd)/signing/KizakiWorks.keychain"
SIGNED=0
if [ -f "$KC" ]; then
    echo "==> signing with stable identity (KizakiWorks Local)"
    security unlock-keychain -p "dpipeek" "$KC" 2>/dev/null || true
    if codesign --force --keychain "$KC" --sign "KizakiWorks Local" \
            --identifier com.kizakiworks.dpipeek "$APP" 2>/dev/null; then
        SIGNED=1
    else
        echo "   (stable identity failed, falling back to ad-hoc)"
    fi
fi

if [ "$SIGNED" != "1" ]; then
    echo "==> ad-hoc signing"
    codesign --force --sign - --identifier com.kizakiworks.dpipeek "$APP" >/dev/null 2>&1 || \
        echo "   (codesign failed — app still runs locally)"
fi

mkdir -p logs
echo "==> done: $PWD/$APP"
echo "   logs land in: $PWD/logs"
