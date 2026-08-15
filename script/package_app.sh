#!/usr/bin/env bash
set -euo pipefail

# Builds the Swift package and stages `dist/Volume Mixer.app`.
# Shared by script/build_and_run.sh and the release workflow so a downloaded
# build is assembled exactly like a local one.
#
# Environment:
#   VOLUME_MIXER_CONFIGURATION  swift build configuration (default: release)
#   VOLUME_MIXER_UNIVERSAL      1 to build arm64 + x86_64 (default: host only)
#   CODESIGN_IDENTITY           signing identity (default: "-", ad-hoc)
#   MARKETING_VERSION           overrides CFBundleShortVersionString
#   BUILD_VERSION               overrides CFBundleVersion

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXECUTABLE_NAME="VolumeMixer"
DISPLAY_NAME="Volume Mixer"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

CONFIGURATION="${VOLUME_MIXER_CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

cd "$ROOT_DIR"

# Released builds are universal: the CI runners are Apple Silicon, so a plain
# `swift build` produces an arm64-only binary that Intel Macs cannot launch.
ARCH_FLAGS=""
if [ "${VOLUME_MIXER_UNIVERSAL:-0}" = "1" ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

# Unquoted on purpose: word splitting is how the flags reach swift build.
# shellcheck disable=SC2086
swift build -c "$CONFIGURATION" $ARCH_FLAGS
# shellcheck disable=SC2086
BUILD_BINARY="$(swift build -c "$CONFIGURATION" $ARCH_FLAGS --show-bin-path)/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/AppBundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/AppBundle/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
# The menu-bar glyph is read from Bundle.main at runtime, so it has to be staged
# here. Without it the app silently falls back to an SF Symbol.
cp "$ROOT_DIR/Sources/VolumeMixer/Resources/MenuBarIcon.png" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png"
chmod +x "$APP_BINARY"

if [ -n "${MARKETING_VERSION:-}" ]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi
if [ -n "${BUILD_VERSION:-}" ]; then
  /usr/bin/plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi

# Signing must come last: it seals the bundle, so any later edit breaks it.
codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
codesign --verify --strict "$APP_BUNDLE"

echo "staged $APP_BUNDLE"
