#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Seeker"
VERSION="1.0.0"
INSTALL=false
VERSION_SET=false
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=true ;;
        --help|-h)
            echo "Usage: $0 [version] [--install]"
            echo "Default: create a release DMG. --install: install and launch instead."
            echo "INSTALL_DIR overrides /Applications; SIGN_IDENTITY overrides signing."
            exit 0
            ;;
        -*)
            echo "Unknown option: $argument" >&2
            exit 1
            ;;
        *)
            if [[ "$VERSION_SET" == true || ! "$argument" =~ ^[0-9]+(\.[0-9]+)*([A-Za-z0-9.-]*)$ ]]; then
                echo "Invalid or duplicate version: $argument" >&2
                exit 1
            fi
            VERSION="$argument"
            VERSION_SET=true
            ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
INSTALL_STAGE=""
INSTALL_LOCK=""
INSTALL_STARTED=false
INSTALL_SUCCEEDED=false
HAD_PREVIOUS=false
WAS_RUNNING=false
BUILD_DIR=""

app_is_running() {
    local pattern
    pattern="$(printf '%s' "$INSTALLED_APP/Contents/MacOS/$APP_NAME" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    local status=0
    pgrep -f "^${pattern}([[:space:]]|$)" > /dev/null || status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) echo "Could not check whether $APP_NAME is running." >&2; exit "$status" ;;
    esac
}

stop_installed_app() {
    if ! app_is_running; then return 0; fi
    if ! osascript - "$INSTALLED_APP" <<'APPLESCRIPT'
on run argv
    set appPath to item 1 of argv
    with timeout of 30 seconds
        tell application appPath to quit
    end timeout
end run
APPLESCRIPT
    then
        echo "Could not ask $APP_NAME to quit." >&2
        return 1
    fi
    local attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! app_is_running; then return 0; fi
        sleep 1
    done
    echo "$APP_NAME did not quit within 30 seconds; refusing to replace a running app." >&2
    return 1
}

cleanup() {
    local status=$?
    local keep_stage=false
    trap - EXIT
    if [[ "$INSTALL_STARTED" == true && "$INSTALL_SUCCEEDED" == false ]]; then
        if [[ -e "$INSTALL_STAGE/previous.app" || "$HAD_PREVIOUS" == false ]]; then
            echo "==> Installation failed; rolling back..." >&2
            if ! stop_installed_app; then
                keep_stage=true
            elif [[ -e "$INSTALLED_APP" ]] && ! mv "$INSTALLED_APP" "$INSTALL_STAGE/failed.app"; then
                keep_stage=true
            elif [[ -e "$INSTALL_STAGE/previous.app" ]]; then
                if ! mv "$INSTALL_STAGE/previous.app" "$INSTALLED_APP"; then
                    keep_stage=true
                elif [[ "$WAS_RUNNING" == true ]]; then
                    if ! open -n "$INSTALLED_APP"; then
                        echo "Restored the old app, but could not relaunch it." >&2
                        status=1
                    fi
                fi
            fi
        fi
    fi
    if [[ "$keep_stage" == true ]]; then
        echo "Automatic rollback failed. Backup and staging files retained at: $INSTALL_STAGE" >&2
        status=1
    elif [[ -n "$INSTALL_STAGE" ]]; then
        if ! rm -rf "$INSTALL_STAGE"; then status=1; fi
    fi
    if [[ -n "$INSTALL_LOCK" ]]; then
        if ! rmdir "$INSTALL_LOCK"; then status=1; fi
    fi
    if [[ -n "$BUILD_DIR" ]]; then
        if ! rm -rf "$BUILD_DIR"; then status=1; fi
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$INSTALL" == true ]]; then
    if [[ "$INSTALL_DIR" != /* || ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
        echo "Installation directory must be absolute, existing and writable: $INSTALL_DIR" >&2
        exit 1
    fi
    if [[ -L "$INSTALLED_APP" || ( -e "$INSTALLED_APP" && ! -d "$INSTALLED_APP" ) ]]; then
        echo "Refusing to replace a symlink or non-directory: $INSTALLED_APP" >&2
        exit 1
    fi
    if ! mkdir "$INSTALL_DIR/.$APP_NAME-install-lock"; then
        echo "Could not acquire the install lock; another installation may be running." >&2
        exit 1
    fi
    INSTALL_LOCK="$INSTALL_DIR/.$APP_NAME-install-lock"
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-build.XXXXXX")"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_DIR="${BUILD_DIR}/dmg"
DMG_OUTPUT="${PROJECT_DIR}/dist/${APP_NAME}-${VERSION}.dmg"

# Linker flags: dead-strip unreachable symbols and unused dylibs to shrink
# the release binary.
LINKER_FLAGS=(-Xlinker -dead_strip -Xlinker -dead_strip_dylibs)

echo "==> Building ${APP_NAME} v${VERSION} (arm64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64   "${LINKER_FLAGS[@]}"
BIN_DIR="$(swift build -c release --arch arm64 "${LINKER_FLAGS[@]}" --show-bin-path)"
test -x "$BIN_DIR/$APP_NAME"
test -d "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"

echo "==> Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/Seeker"
# Strip local symbols (-x) and debug info (-S) from the shipped binary;
# debug info already lives in the .dSYM elsewhere.
strip -S -x "$APP_BUNDLE/Contents/MacOS/Seeker"

cp Seeker/Sources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Seeker/Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -r "$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle" "$APP_BUNDLE/Contents/Resources/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Code signing (hardened runtime)..."
# Pick a signing identity. If SIGN_IDENTITY is not provided, use the first
# valid codesigning identity in the keychain. When none exists (e.g. the
# Apple Development cert was revoked/removed), fall back to ad-hoc signing so
# the app still runs locally. A secure --timestamp requires a real cert, so it
# is only used for genuine identities; ad-hoc signatures use --timestamp=none.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*) [0-9A-F]* "\(.*\)"/\1/p' | sed -n '1p')"
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

if [[ "$INSTALL" == true ]]; then
    echo "==> Staging installation..."
    INSTALL_STAGE="$(mktemp -d "$INSTALL_DIR/.$APP_NAME-install.XXXXXX")"
    ditto "$APP_BUNDLE" "$INSTALL_STAGE/new.app"
    codesign --verify --strict --verbose=2 "$INSTALL_STAGE/new.app"

    echo "==> Quitting the installed app, if running..."
    if app_is_running; then WAS_RUNNING=true; fi
    stop_installed_app

    echo "==> Installing to $INSTALLED_APP..."
    if [[ -e "$INSTALLED_APP" ]]; then HAD_PREVIOUS=true; fi
    INSTALL_STARTED=true
    if [[ "$HAD_PREVIOUS" == true ]]; then
        mv "$INSTALLED_APP" "$INSTALL_STAGE/previous.app"
    fi
    mv "$INSTALL_STAGE/new.app" "$INSTALLED_APP"
    codesign --verify --strict --verbose=2 "$INSTALLED_APP"
    diff -qr "$APP_BUNDLE" "$INSTALLED_APP"

    echo "==> Launching and checking the installed app..."
    open -n "$INSTALLED_APP"
    sleep 3
    if ! app_is_running; then
        echo "The installed app did not remain running; restoring the previous version." >&2
        exit 1
    fi
    INSTALL_SUCCEEDED=true
    echo "Install complete: $INSTALLED_APP"
    exit 0
fi

echo "==> Creating DMG..."
mkdir -p "$DMG_DIR" "$(dirname "$DMG_OUTPUT")"
cp -r "$APP_BUNDLE" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_OUTPUT"

echo ""
echo "Build complete!"
echo "  DMG: $DMG_OUTPUT"
echo ""
echo "File sizes:"
ls -lh "$DMG_OUTPUT"
