#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTABLE_NAME="VolumeMixer"
DISPLAY_NAME="Volume Mixer"
BUNDLE_ID="com.ydps915.VolumeMixer"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/AppBundle/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
chmod +x "$APP_BINARY"
codesign --force --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
