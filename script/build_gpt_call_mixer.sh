#!/usr/bin/env bash

set -euo pipefail

# Builds, ad-hoc signs, and verifies GPT Call Mixer locally. This script never
# installs a HAL plug-in, invokes sudo, launches an app, restarts Core Audio,
# changes a permission, or touches the existing MeetVoiceBridge artifacts.

readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly BUILD_ROOT="$PROJECT_ROOT/.build/gpt-call-mixer"
readonly MODULE_CACHE="$BUILD_ROOT/module-cache"
readonly DIST_ROOT="$PROJECT_ROOT/dist"
readonly APP_OUTPUT="$DIST_ROOT/GPTCallMixer.app"
readonly DRIVER_OUTPUT="$DIST_ROOT/GPTCallMixerDrivers"
readonly ARCHIVE_OUTPUT="$DIST_ROOT/GPTCallMixer-local-build.zip"
readonly MIN_VERSION="14.2"
# Target architectures. Default is a universal (Apple Silicon + Intel) build so
# the HAL drivers load natively in coreaudiod on either kind of Mac.
# Override with e.g. GPT_CALL_MIXER_ARCHS="x86_64" for the previous Intel-only build.
readonly TARGET_ARCHS="${GPT_CALL_MIXER_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for target_arch in $TARGET_ARCHS; do
    case "$target_arch" in
        arm64|x86_64) ARCH_FLAGS+=(-arch "$target_arch") ;;
        *) printf 'GPT Call Mixer build error: unsupported arch: %s\n' "$target_arch" >&2; exit 2 ;;
    esac
done
[[ "${#ARCH_FLAGS[@]}" -gt 0 ]] || { printf 'GPT Call Mixer build error: no target arch\n' >&2; exit 2; }
readonly HOST_ARCH="$(uname -m)"

die() {
    printf 'GPT Call Mixer build error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./script/build_gpt_call_mixer.sh [--verify]

Builds and ad-hoc signs the GPT Call Mixer app (universal arm64 + x86_64 by
default; set GPT_CALL_MIXER_ARCHS to override) and its two local
AudioServerPlugIn bundles. --verify is accepted as an explicit reminder that
the command only builds/verifies; installation and launch never occur.
USAGE
}

case "${1:-}" in
    ""|--verify) ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { usage >&2; exit 2; }

for command_name in xcrun codesign plutil lipo nm file ditto cmp xattr unzip; do
    command -v "$command_name" >/dev/null 2>&1 || die "必要なコマンドがありません: $command_name"
done

[[ ! -L "$BUILD_ROOT" ]] || die "build rootがsymlinkです: $BUILD_ROOT"
[[ ! -L "$DIST_ROOT" ]] || die "dist rootがsymlinkです: $DIST_ROOT"
[[ "$APP_OUTPUT" == "$PROJECT_ROOT/dist/GPTCallMixer.app" ]] || die "app出力先の検証に失敗しました"
[[ "$DRIVER_OUTPUT" == "$PROJECT_ROOT/dist/GPTCallMixerDrivers" ]] || die "driver出力先の検証に失敗しました"
[[ "$ARCHIVE_OUTPUT" == "$PROJECT_ROOT/dist/GPTCallMixer-local-build.zip" ]] || die "archive出力先の検証に失敗しました"

for input_file in \
    GPTCallMixerApp/main.m \
    GPTCallMixerApp/GPTCallMixerEngine.mm \
    GPTCallMixerApp/GPTCallMixerEngine.h \
    GPTCallMixerApp/AudioRingBuffer.hpp \
    GPTCallMixerApp/AudioProcessFamilies.h \
    GPTCallMixerApp/Info.plist \
    Driver/GPTCallMixer.c \
    Driver/LICENSE.txt \
    Driver/Info-ChatGPT.plist \
    Driver/Info-Call.plist \
    Tests/AudioRingBufferTests.cpp \
    Tests/MeetNotesModeTests.m \
    Tests/AudioProcessFamilyTests.m; do
    [[ -f "$PROJECT_ROOT/$input_file" ]] || die "必須入力がありません: $input_file"
done

/bin/mkdir -p "$BUILD_ROOT" "$MODULE_CACHE" "$DIST_ROOT"
readonly STAGE_ROOT="$(mktemp -d /tmp/gpt-call-mixer-package.XXXXXX)"
[[ "$STAGE_ROOT" == /tmp/gpt-call-mixer-package.* ]] || die "temporary stageの検証に失敗しました"
trap '/bin/rm -rf -- "$STAGE_ROOT"' EXIT

readonly APP_STAGE="$STAGE_ROOT/GPTCallMixer.app"
readonly CHATGPT_DRIVER="$STAGE_ROOT/GPTCallMixer-ChatGPT.driver"
readonly CALL_DRIVER="$STAGE_ROOT/GPTCallMixer-Call.driver"
readonly SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
readonly CLANG="$(xcrun --sdk macosx --find clang)"
readonly CLANGXX="$(xcrun --sdk macosx --find clang++)"

/bin/mkdir -p "$APP_STAGE/Contents/MacOS" \
    "$CHATGPT_DRIVER/Contents/MacOS" "$CHATGPT_DRIVER/Contents/Resources" \
    "$CALL_DRIVER/Contents/MacOS" "$CALL_DRIVER/Contents/Resources"

"$CLANGXX" "${ARCH_FLAGS[@]}" -isysroot "$SDK_PATH" -std=c++17 -fobjc-arc -fblocks -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" -mmacosx-version-min="$MIN_VERSION" -O2 \
    -Wall -Wextra -Werror -c "$PROJECT_ROOT/GPTCallMixerApp/GPTCallMixerEngine.mm" \
    -o "$BUILD_ROOT/GPTCallMixerEngine.o"

"$CLANG" "${ARCH_FLAGS[@]}" -isysroot "$SDK_PATH" -fobjc-arc -fblocks -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" -mmacosx-version-min="$MIN_VERSION" -O2 \
    -Wall -Wextra -Werror -c "$PROJECT_ROOT/GPTCallMixerApp/main.m" \
    -o "$BUILD_ROOT/GPTCallMixerMain.o"

"$CLANGXX" "${ARCH_FLAGS[@]}" -isysroot "$SDK_PATH" -std=c++17 -fobjc-arc -fblocks \
    -mmacosx-version-min="$MIN_VERSION" -O2 \
    "$BUILD_ROOT/GPTCallMixerMain.o" "$BUILD_ROOT/GPTCallMixerEngine.o" \
    -framework AppKit -framework Foundation -framework CoreAudio \
    -o "$APP_STAGE/Contents/MacOS/GPTCallMixer"
/bin/cp "$PROJECT_ROOT/GPTCallMixerApp/Info.plist" "$APP_STAGE/Contents/Info.plist"

"$CLANGXX" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -std=c++17 -O2 -Wall -Wextra -Werror \
    "$PROJECT_ROOT/Tests/AudioRingBufferTests.cpp" -o "$BUILD_ROOT/AudioRingBufferTests"
"$BUILD_ROOT/AudioRingBufferTests"

# Controller regressions use a fake audio engine and isolated preferences.
# A cross-only build still needs a native engine object to run these tests.
TEST_ENGINE_OBJECT="$BUILD_ROOT/GPTCallMixerEngine.o"
if ! lipo -verify_arch "$HOST_ARCH" "$TEST_ENGINE_OBJECT" >/dev/null 2>&1; then
    TEST_ENGINE_OBJECT="$BUILD_ROOT/GPTCallMixerEngine-test-host.o"
    "$CLANGXX" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -std=c++17 -fobjc-arc -fblocks -fmodules \
        -fmodules-cache-path="$MODULE_CACHE" -mmacosx-version-min="$MIN_VERSION" -O2 \
        -Wall -Wextra -Werror -c "$PROJECT_ROOT/GPTCallMixerApp/GPTCallMixerEngine.mm" \
        -o "$TEST_ENGINE_OBJECT"
fi
"$CLANG" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -std=c11 -fobjc-arc -fblocks -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" -mmacosx-version-min="$MIN_VERSION" -O2 \
    -Wall -Wextra -Werror -c "$PROJECT_ROOT/Tests/MeetNotesModeTests.m" \
    -o "$BUILD_ROOT/MeetNotesModeTests.o"
"$CLANGXX" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_VERSION" \
    "$BUILD_ROOT/MeetNotesModeTests.o" "$TEST_ENGINE_OBJECT" \
    -framework AppKit -framework Foundation -framework CoreAudio \
    -o "$BUILD_ROOT/MeetNotesModeTests"
"$BUILD_ROOT/MeetNotesModeTests"

"$CLANG" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -std=c11 -fobjc-arc -fblocks -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" -mmacosx-version-min="$MIN_VERSION" -O2 \
    -Wall -Wextra -Werror -c "$PROJECT_ROOT/Tests/AudioProcessFamilyTests.m" \
    -o "$BUILD_ROOT/AudioProcessFamilyTests.o"
"$CLANGXX" -arch "$HOST_ARCH" -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_VERSION" \
    "$BUILD_ROOT/AudioProcessFamilyTests.o" "$TEST_ENGINE_OBJECT" \
    -framework AppKit -framework Foundation -framework CoreAudio \
    -o "$BUILD_ROOT/AudioProcessFamilyTests"
"$BUILD_ROOT/AudioProcessFamilyTests"

build_driver() {
    local route="$1"
    local bundle="$2"
    local executable="$3"
    local plist="$4"

    "$CLANG" "${ARCH_FLAGS[@]}" -isysroot "$SDK_PATH" -mmacosx-version-min="$MIN_VERSION" \
        -std=c11 -fblocks -O2 -Wall -Wextra -Werror -bundle \
        -D GPT_CALL_MIXER_ROUTE="$route" \
        -framework CoreAudio -framework CoreFoundation \
        -Wl,-exported_symbol,_GPTCallMixer_Create \
        -o "$bundle/Contents/MacOS/$executable" "$PROJECT_ROOT/Driver/GPTCallMixer.c"
    /bin/cp "$PROJECT_ROOT/Driver/$plist" "$bundle/Contents/Info.plist"
    /bin/cp "$PROJECT_ROOT/Driver/LICENSE.txt" "$bundle/Contents/Resources/LICENSE.txt"
    /usr/bin/cmp "$PROJECT_ROOT/Driver/LICENSE.txt" "$bundle/Contents/Resources/LICENSE.txt"
}

build_driver 1 "$CHATGPT_DRIVER" GPTCallMixer-ChatGPT Info-ChatGPT.plist
build_driver 2 "$CALL_DRIVER" GPTCallMixer-Call Info-Call.plist

plutil -lint "$APP_STAGE/Contents/Info.plist" \
    "$CHATGPT_DRIVER/Contents/Info.plist" "$CALL_DRIVER/Contents/Info.plist" >/dev/null
/usr/bin/cmp "$PROJECT_ROOT/Driver/LICENSE.txt" "$CHATGPT_DRIVER/Contents/Resources/LICENSE.txt"
/usr/bin/cmp "$PROJECT_ROOT/Driver/LICENSE.txt" "$CALL_DRIVER/Contents/Resources/LICENSE.txt"

verify_archs() {
    local binary="$1"
    local actual
    actual="$(lipo -archs "$binary")"
    for target_arch in $TARGET_ARCHS; do
        [[ " $actual " == *" $target_arch "* ]] || die "$target_arch スライスがありません（$actual）: $binary"
    done
}

verify_archs "$APP_STAGE/Contents/MacOS/GPTCallMixer"
verify_archs "$CHATGPT_DRIVER/Contents/MacOS/GPTCallMixer-ChatGPT"
verify_archs "$CALL_DRIVER/Contents/MacOS/GPTCallMixer-Call"
file "$CHATGPT_DRIVER/Contents/MacOS/GPTCallMixer-ChatGPT" | /usr/bin/grep -q 'Mach-O 64-bit bundle' \
    || die "ChatGPT driverがMH_BUNDLEではありません"
file "$CALL_DRIVER/Contents/MacOS/GPTCallMixer-Call" | /usr/bin/grep -q 'Mach-O 64-bit bundle' \
    || die "Call driverがMH_BUNDLEではありません"
nm -gU "$CHATGPT_DRIVER/Contents/MacOS/GPTCallMixer-ChatGPT" | /usr/bin/grep -q '_GPTCallMixer_Create' \
    || die "ChatGPT driver factory symbolがありません"
nm -gU "$CALL_DRIVER/Contents/MacOS/GPTCallMixer-Call" | /usr/bin/grep -q '_GPTCallMixer_Create' \
    || die "Call driver factory symbolがありません"

xattr -cr "$STAGE_ROOT"
codesign --force --deep --sign - "$APP_STAGE"
codesign --force --sign - "$CHATGPT_DRIVER"
codesign --force --sign - "$CALL_DRIVER"
codesign --verify --deep --strict --verbose=2 "$APP_STAGE"
codesign --verify --strict --verbose=2 "$CHATGPT_DRIVER"
codesign --verify --strict --verbose=2 "$CALL_DRIVER"

# Preserve the verified payload in an archive. A file provider backing the
# Documents directory can attach FinderInfo to a loose .app after this script
# exits, invalidating strict code-signature verification even though the bytes
# are unchanged. The archive is the canonical local-build artifact.
readonly PACKAGE_STAGE="$STAGE_ROOT/GPTCallMixer-local-build"
readonly ARCHIVE_VERIFY_STAGE="$STAGE_ROOT/archive-verify"
/bin/mkdir -p "$PACKAGE_STAGE/Drivers" "$ARCHIVE_VERIFY_STAGE"
/usr/bin/ditto --noqtn "$APP_STAGE" "$PACKAGE_STAGE/GPTCallMixer.app"
/usr/bin/ditto --noqtn "$CHATGPT_DRIVER" "$PACKAGE_STAGE/Drivers/GPTCallMixer-ChatGPT.driver"
/usr/bin/ditto --noqtn "$CALL_DRIVER" "$PACKAGE_STAGE/Drivers/GPTCallMixer-Call.driver"
xattr -cr "$PACKAGE_STAGE"
codesign --force --deep --sign - "$PACKAGE_STAGE/GPTCallMixer.app"
codesign --force --sign - "$PACKAGE_STAGE/Drivers/GPTCallMixer-ChatGPT.driver"
codesign --force --sign - "$PACKAGE_STAGE/Drivers/GPTCallMixer-Call.driver"

# Replace only this product's generated output. MeetVoiceBridge.app and its
# support files are deliberately outside these exact validated paths.
/bin/rm -rf -- "$APP_OUTPUT" "$DRIVER_OUTPUT"
/bin/rm -f -- "$ARCHIVE_OUTPUT"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent \
    "$PACKAGE_STAGE" "$ARCHIVE_OUTPUT"
if /usr/bin/unzip -Z1 "$ARCHIVE_OUTPUT" | /usr/bin/grep -Eq '(^|/)\._'; then
    die "archiveにAppleDouble sidecarが含まれています"
fi
/usr/bin/ditto -x -k --norsrc --noextattr --noqtn --noacl \
    "$ARCHIVE_OUTPUT" "$ARCHIVE_VERIFY_STAGE"
codesign --verify --deep --strict --verbose=2 "$ARCHIVE_VERIFY_STAGE/GPTCallMixer-local-build/GPTCallMixer.app"
codesign --verify --strict --verbose=2 "$ARCHIVE_VERIFY_STAGE/GPTCallMixer-local-build/Drivers/GPTCallMixer-ChatGPT.driver"
codesign --verify --strict --verbose=2 "$ARCHIVE_VERIFY_STAGE/GPTCallMixer-local-build/Drivers/GPTCallMixer-Call.driver"
/usr/bin/ditto --noqtn "$APP_STAGE" "$APP_OUTPUT"
/bin/mkdir -p "$DRIVER_OUTPUT"
/usr/bin/ditto --noqtn "$CHATGPT_DRIVER" "$DRIVER_OUTPUT/GPTCallMixer-ChatGPT.driver"
/usr/bin/ditto --noqtn "$CALL_DRIVER" "$DRIVER_OUTPUT/GPTCallMixer-Call.driver"

# Documents may be backed by a file provider that attaches Finder metadata
# during the stage-to-dist copy. Clean and sign the final paths themselves so
# the artifacts handed to the user are the artifacts that were verified.
xattr -cr "$DRIVER_OUTPUT"
codesign --force --sign - "$DRIVER_OUTPUT/GPTCallMixer-ChatGPT.driver"
codesign --force --sign - "$DRIVER_OUTPUT/GPTCallMixer-Call.driver"
if ! codesign --verify --deep --strict --verbose=2 "$APP_OUTPUT"; then
    printf 'Warning: Documents file provider changed loose GPTCallMixer.app metadata; use the verified ZIP.\n' >&2
fi
codesign --verify --strict --verbose=2 "$DRIVER_OUTPUT/GPTCallMixer-ChatGPT.driver"
codesign --verify --strict --verbose=2 "$DRIVER_OUTPUT/GPTCallMixer-Call.driver"

printf '\nGPT Call Mixer build: PASS\n'
printf '  App: %s\n' "$APP_OUTPUT"
printf '  Drivers (not installed): %s\n' "$DRIVER_OUTPUT"
printf '  Canonical verified archive: %s\n' "$ARCHIVE_OUTPUT"
printf '  Architectures: %s\n' "$TARGET_ARCHS"
printf '  Signature: ad-hoc (local-only; no Developer ID or notarization)\n'
printf '  Note: loose .app metadata may be changed later by the Documents file provider\n'
printf '  Existing MeetVoiceBridge: untouched\n'
