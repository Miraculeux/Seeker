#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seeker"
VERSION="${1:-1.0.0}"
BUILD_DIR="/tmp/${APP_NAME}-build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_OUTPUT="${PROJECT_DIR}/dist/${APP_NAME}-${VERSION}.dmg"
ZIP_OUTPUT="${PROJECT_DIR}/dist/${APP_NAME}-${VERSION}.zip"

echo "==> Building ${APP_NAME} v${VERSION} (universal binary)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64

echo "==> Creating app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp .build/apple/Products/Release/Seeker "$APP_BUNDLE/Contents/MacOS/Seeker"
cp Seeker/Sources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Seeker/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -r .build/apple/Products/Release/Seeker_Seeker.bundle "$APP_BUNDLE/Contents/Resources/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep "$APP_BUNDLE"

echo "==> Creating DMG..."
mkdir -p "$DMG_DIR" "$(dirname "$DMG_OUTPUT")"
cp -r "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_OUTPUT"

echo "==> Creating ZIP..."
cd "$BUILD_DIR"
zip -ry "$ZIP_OUTPUT" "${APP_NAME}.app"

echo "==> Cleaning up..."
rm -rf "$BUILD_DIR"

echo ""
echo "Build complete!"
echo "  DMG: $DMG_OUTPUT"
echo "  ZIP: $ZIP_OUTPUT"
echo ""
echo "File sizes:"
ls -lh "$DMG_OUTPUT" "$ZIP_OUTPUT"
