#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
BUILD_CONFIGURATION="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  BUILD_CONFIGURATION="debug"
fi
APP_NAME="Viewport"
BUNDLE_ID="com.longden.viewport"
MIN_SYSTEM_VERSION="26.0"
APP_ICON_NAME="AppIcon"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/$APP_ICON_NAME.icon"
MODULE_CACHE_DIR="$ROOT_DIR/.build/swiftpm-module-cache"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

if [[ "$MODE" == "--launch" || "$MODE" == "launch" ]]; then
  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "$APP_BUNDLE does not exist; run the build first." >&2
    exit 1
  fi
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  open_app
  exit 0
fi

mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcrun swift build --disable-sandbox -c "$BUILD_CONFIGURATION"
BUILD_BINARY="$(xcrun swift build --disable-sandbox -c "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ ! -d "$APP_ICON_SOURCE" ]]; then
  echo "Missing app icon at $APP_ICON_SOURCE" >&2
  exit 1
fi

ICON_COMPILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/viewport-icon.XXXXXX")"
cleanup_icon_compile() {
  rm -rf "$ICON_COMPILE_DIR"
}
trap cleanup_icon_compile EXIT

echo "Compiling app icon from $APP_ICON_NAME.icon"
xcrun actool "$APP_ICON_SOURCE" \
  --compile "$ICON_COMPILE_DIR" \
  --output-format human-readable-text \
  --notices \
  --warnings \
  --errors \
  --output-partial-info-plist "$ICON_COMPILE_DIR/partial.plist" \
  --app-icon "$APP_ICON_NAME" \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --platform macosx >/dev/null

cp "$ICON_COMPILE_DIR/Assets.car" "$APP_RESOURCES/Assets.car"
cp "$ICON_COMPILE_DIR/$APP_ICON_NAME.icns" "$APP_RESOURCES/$APP_ICON_NAME.icns"

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
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleIconName</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>Viewport uses video access to display the screen of an iPhone or iPad connected over USB.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

# Prefer a stable Apple Development identity so Screen Recording TCC survives
# rebuilds. Ad-hoc signing changes the CDHash every build, which makes macOS
# show a stale enabled "Viewport" toggle while the new binary is denied.
resolve_signing_identity() {
  if [[ -n "${VIEWPORT_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$VIEWPORT_SIGNING_IDENTITY"
    return
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' \
    | head -1
}

SIGNING_IDENTITY="$(resolve_signing_identity || true)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing with $SIGNING_IDENTITY"
  if [[ -n "${VIEWPORT_SIGNING_IDENTITY:-}" ]]; then
    /usr/bin/codesign \
      --force \
      --deep \
      --options runtime \
      --timestamp=none \
      --identifier "$BUNDLE_ID" \
      --sign "$SIGNING_IDENTITY" \
      "$APP_BUNDLE"
  else
    /usr/bin/codesign \
      --force \
      --deep \
      --identifier "$BUNDLE_ID" \
      --sign "$SIGNING_IDENTITY" \
      "$APP_BUNDLE"
  fi
else
  echo "No Apple Development identity found; using ad-hoc signing (Screen Recording may reset each rebuild)."
  /usr/bin/codesign \
    --force \
    --deep \
    --identifier "$BUNDLE_ID" \
    --sign - \
    "$APP_BUNDLE"
fi

case "$MODE" in
  run)
    open_app
    ;;
  --build-only|build-only)
    echo "Built $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--launch|--build-only|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
