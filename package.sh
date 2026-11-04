#!/bin/bash
# Compila CamPanel y genera el instalador: dist/CamPanel-<version>.dmg
# Uso: ./package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/CamPanel.app"

"$ROOT/build.sh" "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/CamPanel-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/CamPanel.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -quiet -volname "CamPanel $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

echo "Instalador: $DMG  ($(du -sh "$DMG" | cut -f1))"
