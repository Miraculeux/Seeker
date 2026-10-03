#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/Seeker-release-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$TEST_ROOT/mocks"

cat > "$TEST_ROOT/mocks/command" <<'MOCK'
#!/bin/bash
set -euo pipefail
name="$(basename "$0")"
printf '%s' "$name" >> "$MOCK_ROOT/commands"
printf ' %q' "$@" >> "$MOCK_ROOT/commands"
printf '\n' >> "$MOCK_ROOT/commands"
case "$name" in
    swift)
        if [[ " $* " == *" --show-bin-path "* ]]; then echo "$MOCK_ROOT/bin"; fi
        ;;
    strip|sleep) ;;
    security) echo "0 valid identities found" ;;
    codesign)
        for target in "$@"; do :; done
        if [[ "$1" == --verify && "$target" == "$INSTALL_DIR/Seeker.app" &&
              "${FAIL_VERIFY:-false}" == true &&
              "$(cat "$target/Contents/MacOS/Seeker")" == new ]]; then
            echo "Simulated installed signature failure" >&2
            exit 1
        fi
        ;;
    ditto)
        if [[ "${FAIL_COPY:-false}" == true ]]; then exit 1; fi
        cp -R "$1" "$2"
        ;;
    hdiutil)
        for target in "$@"; do :; done
        touch "$target"
        ;;
    pgrep) test -f "$MOCK_ROOT/running" ;;
    osascript)
        cat > /dev/null
        if [[ "${FAIL_QUIT:-false}" == true ]]; then exit 1; fi
        if [[ "${REFUSE_QUIT:-false}" != true ]]; then rm -f "$MOCK_ROOT/running"; fi
        ;;
    open)
        for target in "$@"; do :; done
        if [[ "$(cat "$target/Contents/MacOS/Seeker")" == new ]]; then
            if [[ "${FAIL_LAUNCH:-false}" == true ]]; then
                touch "$MOCK_ROOT/running"
                exit 1
            fi
            if [[ "${CRASH_LAUNCH:-false}" == true ]]; then exit 0; fi
        fi
        touch "$MOCK_ROOT/running"
        ;;
    mv)
        if [[ "${FAIL_REPLACE:-false}" == true && "$1" == */new.app ]]; then exit 1; fi
        /bin/mv "$@"
        ;;
    *) echo "Unexpected mock command: $name" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/mocks/command"
for command in swift strip security codesign ditto hdiutil pgrep osascript open sleep mv; do
    ln -s command "$TEST_ROOT/mocks/$command"
done
export PATH="$TEST_ROOT/mocks:$PATH"

fixture() {
    export MOCK_ROOT="$TEST_ROOT/$1"
    export INSTALL_DIR="$MOCK_ROOT/Applications with spaces"
    export TMPDIR="$MOCK_ROOT/tmp/"
    unset SIGN_IDENTITY
    unset FAIL_VERIFY FAIL_COPY FAIL_QUIT REFUSE_QUIT FAIL_LAUNCH CRASH_LAUNCH FAIL_REPLACE
    mkdir -p "$INSTALL_DIR" "$TMPDIR" "$MOCK_ROOT/bin/Seeker_Seeker.bundle" \
        "$MOCK_ROOT/project/scripts" "$MOCK_ROOT/project/Seeker/Sources" \
        "$MOCK_ROOT/project/Seeker/Resources"
    cp "$PROJECT_DIR/scripts/build-release.sh" "$MOCK_ROOT/project/scripts/"
    cp "$PROJECT_DIR/Seeker/Sources/Info.plist" "$MOCK_ROOT/project/Seeker/Sources/"
    cp "$PROJECT_DIR/Seeker/Resources/AppIcon.icns" "$MOCK_ROOT/project/Seeker/Resources/"
    printf 'new' > "$MOCK_ROOT/bin/Seeker"
    chmod +x "$MOCK_ROOT/bin/Seeker"
    printf 'asset' > "$MOCK_ROOT/bin/Seeker_Seeker.bundle/asset"
    touch "$MOCK_ROOT/commands"
}

old_app() {
    mkdir -p "$INSTALL_DIR/Seeker.app/Contents/MacOS"
    printf 'old' > "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker"
    printf 'stale' > "$INSTALL_DIR/Seeker.app/stale"
}

run_success() {
    if ! bash "$MOCK_ROOT/project/scripts/build-release.sh" "$@" > "$MOCK_ROOT/output" 2>&1; then
        cat "$MOCK_ROOT/output" >&2
        exit 1
    fi
}

run_failure() {
    if bash "$MOCK_ROOT/project/scripts/build-release.sh" "$@" > "$MOCK_ROOT/output" 2>&1; then
        echo "Expected failure: $MOCK_ROOT" >&2
        exit 1
    fi
}

assert_clean() {
    test -z "$(find "$INSTALL_DIR" -name '.Seeker-install*' -print)"
    test -z "$(find "$TMPDIR" -name 'Seeker-build.*' -print)"
}

fixture help
run_success --help
test ! -s "$MOCK_ROOT/commands"
run_failure --unknown
run_failure ../invalid
run_failure 1.1.0 1.2.0
test ! -s "$MOCK_ROOT/commands"
echo "PASS: help and invalid arguments do not build"

fixture dmg
run_success 1.1.0
test -f "$MOCK_ROOT/project/dist/Seeker-1.1.0.dmg"
test ! -e "$INSTALL_DIR/Seeker.app"
grep -q '^hdiutil ' "$MOCK_ROOT/commands"
assert_clean
echo "PASS: existing DMG mode and temporary cleanup"

fixture fresh
run_success --install
test "$(cat "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker")" == new
test -f "$MOCK_ROOT/running"
test ! -d "$MOCK_ROOT/project/dist"
assert_clean
echo "PASS: first installation launches without creating a DMG"

fixture replace
old_app
touch "$MOCK_ROOT/running"
run_success --install 1.1.0
test "$(cat "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker")" == new
test ! -f "$INSTALL_DIR/Seeker.app/stale"
test -f "$MOCK_ROOT/running"
grep -q '^osascript ' "$MOCK_ROOT/commands"
assert_clean
echo "PASS: running app quits and the whole bundle is replaced"

for failure in FAIL_COPY FAIL_QUIT REFUSE_QUIT; do
    fixture "$failure"
    old_app
    touch "$MOCK_ROOT/running"
    export "$failure=true"
    run_failure --install
    test "$(cat "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker")" == old
    test -f "$MOCK_ROOT/running"
    test -f "$INSTALL_DIR/Seeker.app/stale"
    assert_clean
    echo "PASS: $failure leaves the running old app intact"
done

for failure in FAIL_REPLACE FAIL_VERIFY FAIL_LAUNCH CRASH_LAUNCH; do
    fixture "$failure"
    old_app
    touch "$MOCK_ROOT/running"
    export "$failure=true"
    run_failure --install
    test "$(cat "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker")" == old
    test -f "$INSTALL_DIR/Seeker.app/stale"
    test -f "$MOCK_ROOT/running"
    assert_clean
    echo "PASS: $failure restores and relaunches the old app"
done

fixture fresh-failure
export CRASH_LAUNCH=true
run_failure --install
test ! -e "$INSTALL_DIR/Seeker.app"
assert_clean
echo "PASS: failed first installation leaves no broken app"

fixture stopped-rollback
old_app
export FAIL_VERIFY=true
run_failure --install
test "$(cat "$INSTALL_DIR/Seeker.app/Contents/MacOS/Seeker")" == old
test ! -f "$MOCK_ROOT/running"
assert_clean
echo "PASS: rollback does not launch a previously stopped app"

fixture rollback-failure
old_app
export FAIL_LAUNCH=true REFUSE_QUIT=true
run_failure --install
backup="$(find "$INSTALL_DIR" -path '*/previous.app/Contents/MacOS/Seeker' -print)"
test -n "$backup"
test "$(cat "$backup")" == old
test ! -d "$INSTALL_DIR/.Seeker-install-lock"
test -z "$(find "$TMPDIR" -name 'Seeker-build.*' -print)"
grep -q 'Backup and staging files retained at:' "$MOCK_ROOT/output"
echo "PASS: failed rollback retains and reports the old app backup"

fixture locked
mkdir "$INSTALL_DIR/.Seeker-install-lock"
run_failure --install
test -d "$INSTALL_DIR/.Seeker-install-lock"
test ! -s "$MOCK_ROOT/commands"
echo "PASS: concurrent installation lock is respected"

fixture symlink
mkdir "$MOCK_ROOT/other"
ln -s "$MOCK_ROOT/other" "$INSTALL_DIR/Seeker.app"
run_failure --install
test -L "$INSTALL_DIR/Seeker.app"
test ! -s "$MOCK_ROOT/commands"
echo "PASS: symlink destinations are rejected"

echo "All release-script tests passed."
