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

# Refuse to ship anything that names this machine's user or home folder.
PATTERNS=("$(dirname "$HOME")/" "$HOME")
ME="$(id -un)"; [ ${#ME} -ge 4 ] && PATTERNS+=("$ME")
for p in "${PATTERNS[@]}"; do
  if hits="$(LC_ALL=C grep -r -a -l -F -- "$p" "$STAGE")"; then
    echo "DMG would contain '$p' in:" >&2; echo "$hits" >&2; exit 1
  fi
done

DMG="dist/Wirely-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname Wirely -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$(dirname "$STAGE")"
echo "$PWD/$DMG"
shasum -a 256 "$DMG"
