#!/bin/bash
# Package dist/Pal.app into a signed dist/Pal-<version>.dmg (drag-to-Applications).
# Usage: scripts/make-dmg.sh <version>
source "$(dirname "$0")/lib.sh"

VERSION="${1:?usage: make-dmg.sh <version>}"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
[ -d "$APP" ] || die "Missing $APP. Run scripts/build-release.sh first."

log "Making $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
echo "$DMG"
