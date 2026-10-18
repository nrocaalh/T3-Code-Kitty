#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="T3CodeKitty"
BUNDLE="build/${APP_NAME}.app"

swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp Info.plist "$BUNDLE/Contents/Info.plist"
for lang in es en; do
  mkdir -p "$BUNDLE/Contents/Resources/${lang}.lproj"
  cp "Resources/${lang}.lproj/Localizable.strings" "$BUNDLE/Contents/Resources/${lang}.lproj/"
done
cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
for asset in cat_idle cat_working cat_alert cat_sleep; do
  cp "Assets/${asset}.png" "$BUNDLE/Contents/Resources/${asset}.png"
done
codesign --force --sign - "$BUNDLE"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/${APP_NAME}.app"
cp -R "$BUNDLE" "$HOME/Applications/${APP_NAME}.app"

echo "Installed at: $HOME/Applications/${APP_NAME}.app"
