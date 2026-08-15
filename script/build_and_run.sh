#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTABLE_NAME="VolumeMixer"
DISPLAY_NAME="Volume Mixer"
BUNDLE_ID="com.ydps915.VolumeMixer"
APP_BUNDLE="$ROOT_DIR/dist/$DISPLAY_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

# The audio DSP runs in the render callback, so ship an optimized build.
# Override with VOLUME_MIXER_CONFIGURATION=debug when you need symbols.
case "$MODE" in
  --debug|debug) export VOLUME_MIXER_CONFIGURATION="${VOLUME_MIXER_CONFIGURATION:-debug}" ;;
  *)             export VOLUME_MIXER_CONFIGURATION="${VOLUME_MIXER_CONFIGURATION:-release}" ;;
esac

# An ad-hoc signature ("-") pins the app's cdhash, so macOS treats every rebuild
# as a different app and the System Audio Recording permission has to be granted
# again. Set CODESIGN_IDENTITY to a self-signed or Developer ID identity to keep
# the grant across builds:
#   CODESIGN_IDENTITY="Volume Mixer Dev" ./script/build_and_run.sh
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$ROOT_DIR"

# Compile before stopping the running copy. Killing first meant a failed build
# left the user with no mixer at all, and every app snapped back to full volume.
swift build -c "$VOLUME_MIXER_CONFIGURATION"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

"$ROOT_DIR/script/package_app.sh" >/dev/null

if [ "$CODESIGN_IDENTITY" = "-" ]; then
  echo "note: ad-hoc signed; macOS may ask for System Audio Recording again." >&2
fi

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
