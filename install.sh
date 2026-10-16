#!/bin/bash
# Installs (or updates) HP Professor 1 DPI in /Applications so it is easy to find in
# 系統設定 → 隱私權與安全性 → 輸入監控, and available to Login Items.
#
# Run this after ./build.sh whenever you want the installed copy refreshed.
# The app keeps the same code-signing identity, so the Input Monitoring
# permission survives updates.
set -euo pipefail
cd "$(dirname "$0")"

SRC="build.noindex/HP Professor 1 DPI.app"
if [ ! -d "$SRC" ]; then
    echo "$SRC not found — run ./build.sh first"
    exit 1
fi

echo "==> quitting any running copy"
pkill -TERM -f "DPIPeek.app/Contents/MacOS/DPIPeek" 2>/dev/null || true
pkill -TERM -f "HP Professor 1 DPI.app/Contents/MacOS/HPProfessor1DPI" 2>/dev/null || true
sleep 1

DEST="/Applications"
if [ ! -w "$DEST" ]; then
    echo "   /Applications is not writable, using ~/Applications instead"
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi

# Clean up older DPIPeek.app if present
rm -rf "$DEST/DPIPeek.app"

echo "==> installing to $DEST/HP Professor 1 DPI.app"
rm -rf "$DEST/HP Professor 1 DPI.app"
cp -R "$SRC" "$DEST/"

echo "==> launched"
open "$DEST/HP Professor 1 DPI.app"
sleep 2
echo "==> installed. logs: /Applications/logs/  (or ~/Library/Logs/HP Professor 1 DPI/ if not writable)"
