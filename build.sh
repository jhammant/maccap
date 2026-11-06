#!/bin/bash
# Builds MacCap.app with swiftc (no Xcode project) and signs it.
#
#   ./build.sh            build into build/MacCap.app
#   ./build.sh install    build, then copy to /Applications/MacCap.app
#   ./build.sh test       build, then run the self-tests
#
# Signing: set MACCAP_SIGN_IDENTITY to a codesigning identity. Keep it the same
# across builds: macOS ties the microphone and system-audio grants to the
# signature, so a stable identity means you only click Allow once. Without it
# the app is ad-hoc signed and macOS asks again after every build.
# MACCAP_BUNDLE_ID overrides the bundle identifier (default io.maccap.MacCap).
set -euo pipefail
cd "$(dirname "$0")"
# Local, uncommitted settings (bundle id, signing identity) live here.
# (release.sh sets MACCAP_SKIP_LOCAL_ENV so its own settings win.)
[ -f build.local.env ] && [ -z "${MACCAP_SKIP_LOCAL_ENV:-}" ] && . ./build.local.env

VERSION="${MACCAP_VERSION:-0.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
BUNDLE_ID="${MACCAP_BUNDLE_ID:-io.maccap.MacCap}"
IDENTITY="${MACCAP_SIGN_IDENTITY:--}"
APP="build/MacCap.app"

mkdir -p build/module-cache "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path build/module-cache \
  -o "$APP/Contents/MacOS/MacCap" Sources/*.swift
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
# Notarization needs a secure timestamp; everyday builds skip the network call.
TIMESTAMP="--timestamp=none"
[ -n "${MACCAP_TIMESTAMP:-}" ] && TIMESTAMP="--timestamp"
codesign --force --options runtime "$TIMESTAMP" \
  --entitlements Resources/MacCap.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($BUNDLE_ID $VERSION build $BUILD_NUMBER, signed by: $IDENTITY)"

case "${1:-}" in
  install)
    # /Applications, with every other app (MACCAP_INSTALL_DIR to change it).
    DEST="${MACCAP_INSTALL_DIR:-/Applications}"
    if pgrep -x MacCap >/dev/null; then
      echo "MacCap is running. Quit it from the menu bar (it finishes any recording first), then re-run." >&2
      exit 1
    fi
    # One copy only: the one being replaced, and any left in the old
    # ~/Applications location, move into build/ (never deleted).
    for OLD in "$DEST/MacCap.app" "$HOME/Applications/MacCap.app"; do
      if [ -d "$OLD" ]; then
        mv "$OLD" "build/MacCap.previous.$(date +%s)-$RANDOM.app"
      fi
    done
    ditto "$APP" "$DEST/MacCap.app"
    echo "installed $DEST/MacCap.app"
    ;;
  test)
    "$APP/Contents/MacOS/MacCap" selftest
    ;;
esac
