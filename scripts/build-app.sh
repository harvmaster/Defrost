#!/usr/bin/env bash
# Builds a universal, signed Defrost.app into ./build.
#
#   VERSION       marketing version (default: latest git tag without "v", else 0.1.0)
#   BUILD_NUMBER  bundle version (default: git commit count, else 1)
#   SIGN_IDENTITY codesign identity (default: first "Developer ID Application" in the keychain, else ad-hoc "-")
#   TIMESTAMP=1   request a secure timestamp (needed for notarization; release.sh sets it)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

echo "==> Building Defrost $VERSION ($BUILD_NUMBER), universal release"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Defrost"

APP=build/Defrost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Defrost"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with: $SIGN_IDENTITY"
SIGN_ARGS=(--force --options runtime --entitlements Resources/Defrost.entitlements --sign "$SIGN_IDENTITY")
[[ "${TIMESTAMP:-0}" == 1 ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "==> $APP"
