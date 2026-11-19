#!/bin/bash
# Build a Developer ID–signed, hardened Pal.app into dist/.
# Usage: scripts/build-release.sh <version> [build-number]
source "$(dirname "$0")/lib.sh"

VERSION="${1:?usage: build-release.sh <version> [build]}"
BUILD="${2:-$(git -C "$ROOT" rev-list --count HEAD)}"
TEAM="$(team_id)"
[ -n "$TEAM" ] || die "No Apple team. Set PAL_TEAM_ID or DEVELOPMENT_TEAM in Config/Local.xcconfig."

log "Building $APP_NAME $VERSION ($BUILD) for team $TEAM"
cd "$ROOT"
xcodegen generate --quiet
xcodebuild -project Pal.xcodeproj -scheme Pal -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build -quiet

rm -rf "$DIST/$APP_NAME.app"
mkdir -p "$DIST"
ditto "$DERIVED/Build/Products/Release/$APP_NAME.app" "$DIST/$APP_NAME.app"
APP="$DIST/$APP_NAME.app"

# Re-sign inside-out so every nested Sparkle helper carries our Developer ID,
# the hardened runtime and a secure timestamp (required for notarization).
log "Signing"
sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ROOT/Pal/Pal.entitlements" "$APP"

codesign --verify --deep --strict "$APP"
log "Built $APP"
