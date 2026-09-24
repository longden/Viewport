#!/usr/bin/env bash
# Build unsigned distribution archives (.zip and optional .dmg) from dist/Viewport.app.
# Signing / notarization can be added later; this script packages whatever is already built.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Viewport"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
VERSION="${VIEWPORT_VERSION:-0.1.0}"
STAGING_DIR="$DIST_DIR/package-staging"
ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-unsigned.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-unsigned.dmg"
MAKE_DMG=1

usage() {
  cat <<EOF
Usage: $0 [--zip-only] [--version <semver>]

Packages an already-built $APP_NAME.app into unsigned archives under dist/.

  --zip-only          Skip .dmg creation (zip only)
  --version <semver>  Version label in archive names (default: $VERSION or VIEWPORT_VERSION)

Prerequisite: a built dist/$APP_NAME.app bundle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip-only)
      MAKE_DMG=0
      shift
      ;;
    --version)
      VERSION="${2:?--version requires a value}"
      ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-unsigned.zip"
      DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-unsigned.dmg"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing $APP_BUNDLE" >&2
  echo "Build the app bundle before packaging." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"

rm -f "$ZIP_PATH"
(
  cd "$STAGING_DIR"
  /usr/bin/ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH"
)
echo "Wrote $ZIP_PATH"

if [[ "$MAKE_DMG" -eq 1 ]]; then
  rm -f "$DMG_PATH"
  /usr/bin/hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
  echo "Wrote $DMG_PATH"
fi

rm -rf "$STAGING_DIR"
echo "Packaging complete (unsigned). Codesign/notarize before distributing broadly."
