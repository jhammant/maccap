#!/bin/bash
# Builds a signed, notarized MacCap DMG for a GitHub release.
#
#   ./release.sh 0.1.0            build, sign, notarize, staple: dist/MacCap-0.1.0.dmg
#   SKIP_NOTARIZE=1 ./release.sh 0.1.0   everything but notarization (to check the DMG)
#
# Needs a "Developer ID Application" signing identity (MACCAP_RELEASE_IDENTITY,
# or the first one in the keychain), and notarytool credentials: either a
# stored profile (MACCAP_NOTARY_PROFILE, from `xcrun notarytool
# store-credentials`) or an App Store Connect API key (ASC_KEY_PATH, ASC_KEY_ID,
# ASC_ISSUER_ID). Settings can live in the uncommitted build.local.env.
set -euo pipefail
cd "$(dirname "$0")"
[ -f build.local.env ] && . ./build.local.env

VERSION="${1:?usage: ./release.sh VERSION}"
IDENTITY="${MACCAP_RELEASE_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application identity. Create one in Xcode > Settings > Accounts >" >&2
  echo "Manage Certificates (the team's Account Holder can), or set MACCAP_RELEASE_IDENTITY." >&2
  [ -n "${SKIP_NOTARIZE:-}" ] || exit 1
  IDENTITY="${MACCAP_SIGN_IDENTITY:--}"
  echo "SKIP_NOTARIZE: signing with $IDENTITY instead (for checking the DMG only)." >&2
fi

notary() {
  if [ -n "${MACCAP_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool "$@" --keychain-profile "$MACCAP_NOTARY_PROFILE"
  else
    xcrun notarytool "$@" --key "${ASC_KEY_PATH:?set MACCAP_NOTARY_PROFILE or ASC_KEY_PATH}" \
      --key-id "${ASC_KEY_ID:?}" --issuer "${ASC_ISSUER_ID:?}"
  fi
}

MACCAP_SKIP_LOCAL_ENV=1 MACCAP_VERSION="$VERSION" MACCAP_SIGN_IDENTITY="$IDENTITY" MACCAP_TIMESTAMP=1 \
  MACCAP_BUNDLE_ID="${MACCAP_RELEASE_BUNDLE_ID:-io.maccap.MacCap}" ./build.sh test

mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/MacCap.app "$STAGE/MacCap.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/MacCap-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "MacCap $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  notary submit "$DMG" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "built $DMG"
echo "sha256 $SHA"
echo "Next: gh release create v$VERSION $DMG, then set version/sha256 in packaging/homebrew/maccap.rb"
