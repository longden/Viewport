#!/usr/bin/env bash
# Assemble a self-contained SwiftPM app. Does not sign or launch it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/version.env"
CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Expected debug or release" >&2; exit 2 ;; esac
APP_BUNDLE="${2:-$ROOT_DIR/dist/Viewport.app}"
case "$APP_BUNDLE" in "$ROOT_DIR/dist/Viewport.app"|"$ROOT_DIR/dist/Viewport-dev.app") ;; *) echo "Bundle must use an existing Viewport path in dist/" >&2; exit 2 ;; esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/swiftpm-module-cache}"
export VIEWPORT_VERSION VIEWPORT_BUILD VIEWPORT_FEED_URL
# Production updates are opt-in: this script does not sign, and Sparkle
# rejects updates for unsigned apps. The release flow sets this explicitly.
export VIEWPORT_UPDATES_ENABLED="${VIEWPORT_UPDATES_ENABLED:-0}"
if [[ "$CONFIGURATION" == debug && "$VIEWPORT_UPDATES_ENABLED" != 0 ]]; then
  echo "Production updates cannot be enabled in debug builds" >&2
  exit 1
fi
python3 "$ROOT_DIR/script/release_metadata.py" validate-version "$ROOT_DIR"
cd "$ROOT_DIR"
xcrun swift build --disable-sandbox -c "$CONFIGURATION"
BUILD_DIR="$(xcrun swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
FRAMEWORK="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { echo "Sparkle framework missing" >&2; exit 1; }
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
cp "$BUILD_DIR/Viewport" "$APP_BUNDLE/Contents/MacOS/Viewport"
/usr/bin/ditto "$FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
python3 "$ROOT_DIR/script/release_metadata.py" write-plist "$APP_BUNDLE/Contents/Info.plist"
ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/viewport-icon.XXXXXX")"
trap 'rm -rf "$ICON_DIR"' EXIT
xcrun actool "$ROOT_DIR/AppIcon.icon" --compile "$ICON_DIR" \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist "$ICON_DIR/partial.plist" --app-icon AppIcon \
  --include-all-app-icons --enable-on-demand-resources NO --development-region en \
  --target-device mac --minimum-deployment-target 26.0 --platform macosx
cp "$ICON_DIR/Assets.car" "$APP_BUNDLE/Contents/Resources/"
cp "$ICON_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
/usr/bin/otool -L "$APP_BUNDLE/Contents/MacOS/Viewport"
echo "Assembled $APP_BUNDLE"
