#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="T3CodeKitty"
BUNDLE="build/${APP_NAME}.app"
ARCH="$(uname -m)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc \
  -O \
  -swift-version 5 \
  -target "${ARCH}-apple-macos14.0" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  Sources/T3Watcher.swift Sources/CatView.swift Sources/main.swift \
  -o "$BUNDLE/Contents/MacOS/${APP_NAME}"

cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
for asset in cat_idle cat_working cat_alert cat_sleep; do
  cp "Assets/${asset}.png" "$BUNDLE/Contents/Resources/${asset}.png"
done
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/${APP_NAME}.app"
cp -R "$BUNDLE" "$HOME/Applications/${APP_NAME}.app"

echo "Instalado en: $HOME/Applications/${APP_NAME}.app"
