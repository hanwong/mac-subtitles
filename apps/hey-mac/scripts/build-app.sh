#!/bin/bash
# Builds build/HeyMac.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/HeyMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/HeyMac" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# macOS ties granted permissions to the code signature. An ad-hoc signature changes with every build, so
# permissions would have to be granted again each time; a certificate named "Local Dev" in the keychain
# (or CODESIGN_IDENTITY) keeps the signature, and the permissions, stable.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Local Dev"'; then
  IDENTITY="Local Dev"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
