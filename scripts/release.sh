#!/usr/bin/env bash
# End-to-end release pipeline for Pointless.
#
# 1. Archives the app in Release configuration
# 2. Exports with Developer ID signing
# 3. Submits to Apple's notary service and waits
# 4. Staples the notarization ticket
# 5. Produces a notarized DMG via create-dmg
# 6. (optional) Generates a Sparkle appcast entry if SPARKLE_TOOLS_PATH is set
#
# Required env vars:
#   AC_API_KEY_ID   - App Store Connect API key identifier
#   AC_API_ISSUER   - App Store Connect issuer id
#   AC_API_KEY_PATH - Path to the .p8 API key file
#
# Optional env vars:
#   SPARKLE_TOOLS_PATH  - Path to Sparkle's bin/ (for generate_appcast)
#   SPARKLE_PRIVATE_KEY - Path to Sparkle's EdDSA private key file
#   RELEASES_DIR        - Directory to collect published DMGs + appcast (default: ./dist/releases)
#
# Usage:
#   ./scripts/release.sh 1.0.1 2

set -euo pipefail

VERSION="${1:-}"
BUILD="${2:-$(date +%Y%m%d%H%M)}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <marketing-version> [build-number]"
  exit 1
fi

PROJECT="Pointless.xcodeproj"
SCHEME="Pointless"
CONFIG="Release"
APP_NAME="Pointless"

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"
DMG_NAME="$APP_NAME-$VERSION.dmg"
RELEASES_DIR="${RELEASES_DIR:-dist/releases}"

mkdir -p "$BUILD_DIR" "$EXPORT_DIR" "$DMG_DIR" "$RELEASES_DIR"

echo ""
echo "=== 1. Archive ==="
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive | xcpretty || true

echo ""
echo "=== 2. Export (Developer ID signed) ==="
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist | xcpretty || true

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Export failed - app not found at $APP_PATH"
  exit 1
fi

echo ""
echo "=== 3. Submit to notary service ==="
if [[ -z "${AC_API_KEY_ID:-}" || -z "${AC_API_ISSUER:-}" || -z "${AC_API_KEY_PATH:-}" ]]; then
  echo "AC_API_KEY_ID / AC_API_ISSUER / AC_API_KEY_PATH must be set"
  exit 1
fi

ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --key "$AC_API_KEY_PATH" \
  --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER" \
  --wait

echo ""
echo "=== 4. Staple ==="
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo ""
echo "=== 5. Build DMG ==="
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found. Install with: brew install create-dmg"
  exit 1
fi

rm -f "$DMG_DIR/$DMG_NAME"
create-dmg \
  --volname "$APP_NAME $VERSION" \
  --window-size 540 380 \
  --icon-size 120 \
  --icon "$APP_NAME.app" 140 180 \
  --app-drop-link 400 180 \
  --hdiutil-quiet \
  "$DMG_DIR/$DMG_NAME" "$APP_PATH"

xcrun notarytool submit "$DMG_DIR/$DMG_NAME" \
  --key "$AC_API_KEY_PATH" \
  --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER" \
  --wait
xcrun stapler staple "$DMG_DIR/$DMG_NAME"

cp "$DMG_DIR/$DMG_NAME" "$RELEASES_DIR/"

echo ""
echo "=== 6. Sparkle appcast (optional) ==="
if [[ -n "${SPARKLE_TOOLS_PATH:-}" && -x "$SPARKLE_TOOLS_PATH/generate_appcast" ]]; then
  SPARKLE_ARGS=()
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SPARKLE_ARGS+=("--ed-key-file" "$SPARKLE_PRIVATE_KEY")
  fi
  "$SPARKLE_TOOLS_PATH/generate_appcast" "${SPARKLE_ARGS[@]}" "$RELEASES_DIR"
  echo "Updated $RELEASES_DIR/appcast.xml"
else
  echo "SPARKLE_TOOLS_PATH not set, skipping appcast generation"
fi

echo ""
echo "=== 7. Update Homebrew Cask ==="
CASK_PATH="scripts/homebrew/pointless.rb"
if [[ -f "$CASK_PATH" ]]; then
  DMG_SHA256=$(shasum -a 256 "$DMG_DIR/$DMG_NAME" | awk '{ print $1 }')
  # Use sed to replace version and sha256 in the cask file
  sed -i '' "s/version \".*\"/version \"$VERSION\"/g" "$CASK_PATH"
  sed -i '' "s/sha256 \".*\"/sha256 \"$DMG_SHA256\"/g" "$CASK_PATH"
  echo "Updated $CASK_PATH with version $VERSION and sha256 $DMG_SHA256"
  echo ""
  echo "Don't forget to commit $CASK_PATH to your tap repository!"
else
  echo "Cask file not found at $CASK_PATH, skipping Homebrew update."
fi

echo ""
echo "=== Done ==="
echo "DMG: $DMG_DIR/$DMG_NAME"
echo "Published to: $RELEASES_DIR/"

