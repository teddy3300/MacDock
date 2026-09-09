#!/bin/bash
# Build and package a release app for installation or internal distribution.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacDock"
APP_PATH="build/${APP_NAME}.app"
DIST_DIR="dist"

Scripts/build.sh release
codesign --verify --deep --strict "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE" | tr ' ' '-')"
BASE_NAME="${APP_NAME}-${VERSION}-${ARCHITECTURES}"
DMG_PATH="$DIST_DIR/${BASE_NAME}.dmg"
ZIP_PATH="$DIST_DIR/${BASE_NAME}.zip"
CHECKSUM_PATH="$DIST_DIR/${BASE_NAME}.sha256"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH" "$ZIP_PATH" "$CHECKSUM_PATH"

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macdock-package.XXXXXX")"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macdock-mount.XXXXXX")"
MOUNTED=0

cleanup() {
    if [[ "$MOUNTED" -eq 1 ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$STAGE_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH" >/dev/null

if security find-identity -v -p codesigning 2>/dev/null | grep -q "MacDock Development"; then
    codesign --force --sign "MacDock Development" "$DMG_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$DMG_PATH")" "$(basename "$ZIP_PATH")" \
        > "$(basename "$CHECKSUM_PATH")"
)

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1
codesign --verify --deep --strict "$MOUNT_DIR/${APP_NAME}.app"
hdiutil detach "$MOUNT_DIR" -quiet
MOUNTED=0

echo "Packaged release:"
echo "  $DMG_PATH"
echo "  $ZIP_PATH"
echo "  $CHECKSUM_PATH"
