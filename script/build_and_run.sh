#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Viewport"
BUNDLE_ID="com.longden.viewport"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MODULE_CACHE_DIR="$ROOT_DIR/.build/swiftpm-module-cache"
SCREEN_ACCESS_REQUIREMENT_FILE="$DIST_DIR/.viewport-screen-access-requirement"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

code_requirement() {
  /usr/bin/codesign -d --requirements - "$APP_BUNDLE" 2>&1 \
    | /usr/bin/sed -n \
      -e 's/^# designated => /designated => /' \
      -e '/^designated => /p'
}

record_screen_access_requirement() {
  local current_requirement
  current_requirement="$(code_requirement)"

  if [[ -z "$current_requirement" ]]; then
    echo "Could not read the Viewport code requirement." >&2
    exit 1
  fi

  printf '%s\n' "$current_requirement" >"$SCREEN_ACCESS_REQUIREMENT_FILE"
}

prepare_screen_access() {
  local current_requirement
  local approved_requirement=""

  current_requirement="$(code_requirement)"
  if [[ -z "$current_requirement" ]]; then
    echo "Could not read the Viewport code requirement." >&2
    exit 1
  fi

  if [[ -f "$SCREEN_ACCESS_REQUIREMENT_FILE" ]]; then
    approved_requirement="$(<"$SCREEN_ACCESS_REQUIREMENT_FILE")"
  fi

  if [[ "$approved_requirement" != "$current_requirement" ]]; then
    echo "Viewport's code identity changed; clearing its stale Screen Recording entry."
    /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"
  fi

  printf '%s\n' "$current_requirement" >"$SCREEN_ACCESS_REQUIREMENT_FILE"
}

if [[ "$MODE" == "--launch" || "$MODE" == "launch" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "$APP_BUNDLE does not exist; run the build first." >&2
    exit 1
  fi
  prepare_screen_access
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  open_app
  exit 0
fi

mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcrun swift build --disable-sandbox
BUILD_BINARY="$(xcrun swift build --disable-sandbox --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Viewport displays your Android Emulator and iOS Simulator windows together.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

if [[ -n "${VIEWPORT_SIGNING_IDENTITY:-}" ]]; then
  /usr/bin/codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --sign "$VIEWPORT_SIGNING_IDENTITY" \
    "$APP_BUNDLE"
else
  /usr/bin/codesign \
    --force \
    --deep \
    --identifier "$BUNDLE_ID" \
    --sign - \
    "$APP_BUNDLE"
fi

case "$MODE" in
  run)
    prepare_screen_access
    open_app
    ;;
  --reset-screen-access|reset-screen-access)
    /usr/bin/tccutil reset ScreenCapture "$BUNDLE_ID"
    record_screen_access_requirement
    open_app
    ;;
  --build-only|build-only)
    echo "Built $APP_BUNDLE"
    ;;
  --debug|debug)
    prepare_screen_access
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    prepare_screen_access
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    prepare_screen_access
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    prepare_screen_access
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--launch|--reset-screen-access|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
