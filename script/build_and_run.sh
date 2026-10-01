#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MeetVoiceBridge"
CONFIGURATION="debug"
MODE="run"
SHOW_LOGS=0
TELEMETRY=0

for argument in "$@"; do
    case "$argument" in
        --debug)
            MODE="debug"
            ;;
        --logs)
            SHOW_LOGS=1
            ;;
        --telemetry)
            TELEMETRY=1
            ;;
        --verify)
            MODE="verify"
            ;;
        *)
            echo "Unknown option: $argument" >&2
            exit 2
            ;;
    esac
done

cd "$PROJECT_ROOT"

if [ "$MODE" = "verify" ]; then
    swift build -c "$CONFIGURATION"
    VERIFY_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
    "$VERIFY_BINARY" --self-test
    exit 0
fi

swift build -c "$CONFIGURATION"

BINARY_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
cp "$PROJECT_ROOT/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/xattr -cr "$APP_BUNDLE"
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

if [ "$MODE" = "debug" ]; then
    exec /usr/bin/lldb -- "$MACOS_DIR/$APP_NAME"
fi

if [ "$TELEMETRY" -eq 1 ]; then
    export MVB_LOCAL_TELEMETRY=1
fi

/usr/bin/open -n "$APP_BUNDLE"

if [ "$SHOW_LOGS" -eq 1 ]; then
    exec /usr/bin/log stream --style compact --level info --predicate 'subsystem == "jp.local.meetvoicebridge"'
fi
