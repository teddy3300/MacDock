#!/bin/bash
# Build MacDock into a signed .app bundle.
# Usage: Scripts/build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/${CONFIG}/MacDock"
APP="build/MacDock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MacDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/MacDock"

# Generate and embed an app icon (best effort)
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
if swift Scripts/make_icon.swift "$ICONSET" >/dev/null 2>&1; then
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "icon: AppIcon.icns"
  fi
fi

# Stable signature so TCC (screen recording / accessibility) stays attributed to MacDock
# across rebuilds. Falls back to ad-hoc (unstable) if the dev cert is missing.
IDENTITY="MacDock Development"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  if codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "sign: $IDENTITY (stable)"
  else
    echo "warning: codesign with $IDENTITY failed" >&2
  fi
else
  echo "warning: dev cert not found, using ad-hoc signature (TCC will not persist)" >&2
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "✅ Built: $(pwd)/$APP"
