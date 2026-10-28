#!/usr/bin/env bash
# Builds build/Wirely.app (arm64, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v brew >/dev/null || ! brew --prefix wireguard-go >/dev/null 2>&1 \
   || [ ! -x "$(brew --prefix wireguard-go)/bin/wireguard-go" ]; then
  echo "wireguard-go bulunamadi. Kur: brew install wireguard-go" >&2
  exit 1
fi
WG="$(brew --prefix wireguard-go)/bin/wireguard-go"
echo "wireguard-go: $(brew list --versions wireguard-go)"

swift build -c release --arch arm64 --product Wirely
swift build -c release --arch arm64 --product wirely-helper
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/Wirely.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ThirdParty" "$APP/Contents/Resources/Fonts"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/Wirely" "$APP/Contents/MacOS/Wirely"
cp "$BIN/wirely-helper" "$APP/Contents/MacOS/wirely-helper"
cp "$WG" "$APP/Contents/MacOS/wireguard-go"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
cp Resources/ThirdParty/wireguard-go-LICENSE "$APP/Contents/Resources/ThirdParty/wireguard-go-LICENSE"
cp Resources/ThirdParty/Manrope-OFL.txt "$APP/Contents/Resources/ThirdParty/Manrope-OFL.txt"

codesign -f -s - --identifier io.github.luucas42.wirely.wireguard-go "$APP/Contents/MacOS/wireguard-go"
codesign -f -s - --identifier io.github.luucas42.wirely.helper "$APP/Contents/MacOS/wirely-helper"
codesign -f -s - "$APP"
codesign --verify --strict --verbose=2 "$APP"

for f in Wirely wirely-helper wireguard-go; do
  arch="$(lipo -archs "$APP/Contents/MacOS/$f")"
  echo "$f: $arch"
  [ "$arch" = "arm64" ] || { echo "$f arm64 degil" >&2; exit 1; }
done
echo "OK: $APP"
