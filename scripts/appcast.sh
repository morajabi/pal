#!/bin/bash
# Sign the update with the Sparkle key and write dist/appcast.xml for this release.
# The key comes from the login Keychain (account "pal"), or $SPARKLE_PRIVATE_KEY (CI).
# Usage: scripts/appcast.sh <version> <build> <dmg>
source "$(dirname "$0")/lib.sh"

VERSION="${1:?usage: appcast.sh <version> <build> <dmg>}"
BUILD="${2:?}"
DMG="${3:?}"
BIN="$(sparkle_bin)"

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  ATTRS="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$BIN/sign_update" --ed-key-file - "$DMG")"
else
  ATTRS="$("$BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
fi
URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$DIST/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$URL" $ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
log "Wrote $DIST/appcast.xml"
