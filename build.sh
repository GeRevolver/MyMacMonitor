#!/bin/sh
# Build "MyMacMonitor.app" with plain swiftc — no Xcode project, no Homebrew, no xcodegen.
# Output: $BUILD_DIR/MyMacMonitor.app, ad-hoc signed with the hardened runtime.
# BUILD_DIR defaults to a non-synced cache folder: iCloud Drive (Desktop & Documents sync)
# stamps Finder/file-provider xattrs on bundles, which invalidates the code signature.
# It does NOT install or launch anything — see install.sh for that.
set -e
cd "$(dirname "$0")"

BUNDLE_ID="io.github.gerevolver.mymacmonitor"
EXE="MyMacMonitor"
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/MyMacMonitor-build}"
APP="$BUILD_DIR/MyMacMonitor.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13.0 \
  -framework Cocoa -framework CoreAudio -framework ServiceManagement \
  Sources/main.swift -o "$APP/Contents/MacOS/$EXE"

# Resolve the Xcode build variables Info.plist expects.
sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    -e "s/\$(EXECUTABLE_NAME)/$EXE/" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/" \
    Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
codesign --force --sign - --options runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP (not installed)."
