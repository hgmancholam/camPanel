#!/bin/bash
# Compila CamPanel.app y embebe el motor (node + uvcc) dentro del bundle.
# Uso: ./build.sh [destino.app] [--no-embed]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/CamPanel.app}"
EMBED="${2:---embed}"
NAME="CamPanel"
UVCC_VERSION="8.0.0"

# --- localizar node y npm sin depender del PATH del shell que invoca ---
find_node() {
  local d
  for d in "$HOME"/.nvm/versions/node/*/bin /opt/homebrew/bin /usr/local/bin; do
    [ -x "$d/node" ] && { echo "$d/node"; return 0; }
  done
  command -v node 2>/dev/null || return 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/$NAME" \
  "$ROOT/Sources/CamPanel.swift"

# --- motor embebido: la app deja de depender de npm, nvm o del PATH del usuario ---
if [ "$EMBED" != "--no-embed" ]; then
  NODE_BIN="$(find_node)" || { echo "No encuentro node para embeber" >&2; exit 1; }
  NODE_DIR="$(dirname "$NODE_BIN")"
  echo "Embebiendo motor desde $NODE_BIN"
  cp "$NODE_BIN" "$APP/Contents/Resources/node"
  chmod 755 "$APP/Contents/Resources/node"
  mkdir -p "$APP/Contents/Resources/engine"
  PATH="$NODE_DIR:$PATH" npm install \
    --prefix "$APP/Contents/Resources/engine" \
    --no-audit --no-fund --loglevel=error \
    "uvcc@$UVCC_VERSION"
  rm -rf "$APP/Contents/Resources/engine/node_modules/.package-lock.json"
  # el .app no necesita los sourcemaps ni los tipos de TypeScript
  find "$APP/Contents/Resources/engine" \( -name '*.map' -o -name '*.d.ts' \) -delete
fi

# --- icono: se regenera desde el fuente CoreGraphics si hace falta ---
ICNS="$ROOT/Icon/CamPanel.icns"
if [ ! -f "$ICNS" ] && command -v swift >/dev/null 2>&1; then
  ( cd "$ROOT/Icon" && swift make-icon.swift "$ROOT/Icon/CamPanel.iconset" >/dev/null \
    && iconutil -c icns "$ROOT/Icon/CamPanel.iconset" -o "$ICNS" )
fi
[ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/CamPanel.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.campanel</string>
  <key>CFBundleIconFile</key><string>CamPanel</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>CamPanel muestra la imagen de la cámara para que veas el efecto de cada ajuste mientras lo mueves.</string>
  <key>NSHumanReadableCopyright</key><string>Uso personal</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "OK: $APP  ($(du -sh "$APP" | cut -f1))"
