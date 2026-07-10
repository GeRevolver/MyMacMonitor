#!/bin/sh
# Build M9Volume and install a signed copy into /Applications.
#
# Signing: uses $DEVELOPMENT_TEAM if set, else the team of the first codesigning
# identity in the keychain, else falls back to ad-hoc (works, but Accessibility
# permission won't persist across rebuilds — see README).
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found — install with: brew install xcodegen" >&2
  exit 1
}
xcodegen generate

TEAM=${DEVELOPMENT_TEAM:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p' | head -1)}
if [ -n "$TEAM" ]; then
  echo "Signing with team $TEAM"
  SIGN="DEVELOPMENT_TEAM=$TEAM"
else
  echo "warning: no codesigning identity found — using ad-hoc signing." >&2
  SIGN="CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES"
fi

xcodebuild -project M9Volume.xcodeproj -scheme M9Volume -configuration Release \
  -derivedDataPath build $SIGN build

APP=build/Build/Products/Release/M9Volume.app
[ -d "$APP" ] || { echo "error: build product not found at $APP" >&2; exit 1; }

# Replace any running copy, then install with ditto (preserves the signature).
pkill -x M9Volume 2>/dev/null || true
rm -rf /Applications/M9Volume.app
ditto "$APP" /Applications/M9Volume.app

echo "Installed /Applications/M9Volume.app — launching."
open /Applications/M9Volume.app
