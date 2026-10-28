#!/usr/bin/env bash
# Builds dist/Wirely-<version>.dmg (version from Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

STAGE="$(mktemp -d)/Wirely"
mkdir -p "$STAGE" dist
cp -R build/Wirely.app "$STAGE/Wirely.app"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.txt "$STAGE/INSTALL.txt"

DMG="dist/Wirely-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname Wirely -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "$PWD/$DMG"
shasum -a 256 "$DMG"
