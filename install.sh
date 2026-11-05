#!/bin/sh
# Install the app built by build.sh into /Applications and open it.
# Separate from build.sh on purpose: building never touches the system; installing is explicit.
set -e
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/MyMacMonitor-build}"
SRC="$BUILD_DIR/MyMacMonitor.app"
DST="/Applications/MyMacMonitor.app"

[ -d "$SRC" ] || { echo "error: $SRC not found — run ./build.sh first" >&2; exit 1; }
codesign --verify --strict "$SRC"

pkill -x MyMacMonitor 2>/dev/null || true
rm -rf "$DST"
ditto "$SRC" "$DST"          # ditto preserves the signature
codesign --verify --strict --verbose=1 "$DST"
open "$DST"
echo "Installed $DST. Grant Accessibility when prompted, then enable Launch at Login in Settings."
