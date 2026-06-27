#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seeker"
VERSION="${1:-1.0.0}"
BUILD_DIR="/tmp/${APP_NAME}-build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_OUTPUT="${PROJECT_DIR}/dist/${APP_NAME}-${VERSION}.dmg"

# Linker flags: dead-strip unreachable symbols and unused dylibs to shrink
# the release binary.
LINKER_FLAGS=(-Xlinker -dead_strip -Xlinker -dead_strip_dylibs)

echo "==> Building ${APP_NAME} v${VERSION} (arm64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64   "${LINKER_FLAGS[@]}"

echo "==> Creating app bundle..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp .build/arm64-apple-macosx/release/Seeker "$APP_BUNDLE/Contents/MacOS/Seeker"
# Strip local symbols (-x) and debug info (-S) from the shipped binary;
# debug info already lives in the .dSYM elsewhere.
strip -S -x "$APP_BUNDLE/Contents/MacOS/Seeker"

cp Seeker/Sources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Seeker/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -r .build/arm64-apple-macosx/release/Seeker_Seeker.bundle "$APP_BUNDLE/Contents/Resources/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Code signing (hardened runtime)..."
# Pick a signing identity. If SIGN_IDENTITY is not provided, use the first
# valid codesigning identity in the keychain. When none exists (e.g. the
# Apple Development cert was revoked/removed), fall back to ad-hoc signing so
# the app still runs locally. A secure --timestamp requires a real cert, so it
# is only used for genuine identities; ad-hoc signatures use --timestamp=none.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*) [0-9A-F]* "\(.*\)"/\1/p' | head -n1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "    (no valid signing identity found; using ad-hoc signature)"
    SIGN_IDENTITY="-"
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
else
    TIMESTAMP_FLAG="--timestamp"
fi
echo "    (signing identity: $SIGN_IDENTITY)"

# Sign nested bundles first (no --deep: it's deprecated and skips inner
# code-sign requirements). Enable hardened runtime + secure timestamp so the
# binary can be notarised and runs with library validation.
# Skip flat resource bundles (e.g. SwiftPM's *_Module.bundle) which contain
# only assets and no Info.plist/MachO; codesign rejects them.
find "$APP_BUNDLE/Contents" -type d \( -name "*.bundle" -o -name "*.framework" -o -name "*.dylib" \) -print0 \
    | while IFS= read -r -d '' nested; do
        if [[ ! -f "$nested/Contents/Info.plist" && ! -f "$nested/Info.plist" ]]; then
            echo "    (skipping resources-only bundle: $(basename "$nested"))"
            continue
        fi
        codesign --force --options runtime "$TIMESTAMP_FLAG" \
                 --sign "$SIGN_IDENTITY" "$nested"
      done
codesign --force --options runtime "$TIMESTAMP_FLAG" \
         --entitlements Seeker/Seeker.entitlements \
         --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo "==> Creating DMG..."
mkdir -p "$DMG_DIR" "$(dirname "$DMG_OUTPUT")"
cp -r "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_OUTPUT"

echo "==> Cleaning up..."
rm -rf "$BUILD_DIR"

echo ""
echo "Build complete!"
echo "  DMG: $DMG_OUTPUT"
echo ""
echo "File sizes:"
ls -lh "$DMG_OUTPUT"
