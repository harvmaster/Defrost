#!/usr/bin/env bash
# Builds, signs, notarizes and staples dist/Defrost-<version>.dmg.
#
# Requires a "Developer ID Application" identity (SIGN_IDENTITY, or auto-detected)
# and notarization credentials, either:
#   NOTARY_PROFILE=<keychain profile>   created once with:
#       xcrun notarytool store-credentials defrost-notary --apple-id <id> --team-id <team>
# or, for CI:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (an app-specific password)
#
# SKIP_NOTARIZE=1 builds a signed but un-notarized DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

export TIMESTAMP=1
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
[[ -n "${SIGN_IDENTITY:-}" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }
export SIGN_IDENTITY

scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Defrost.app/Contents/Info.plist)"

mkdir -p dist
DMG="dist/Defrost-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Defrost.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create -volname "Defrost $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  else
    echo "Set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_PASSWORD (or SKIP_NOTARIZE=1)" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG"
fi

shasum -a 256 "$DMG"
echo "==> $DMG"
