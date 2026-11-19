#!/bin/bash
# Notarize and staple a DMG (or zip/app).
# Credentials, either:
#   - a notarytool keychain profile (default name "pal-notary"), or
#   - an App Store Connect API key: NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER.
# Usage: scripts/notarize.sh <file>
source "$(dirname "$0")/lib.sh"

FILE="${1:?usage: notarize.sh <file>}"
if [ -n "${NOTARY_KEY_ID:-}" ]; then
  AUTH=(--key "${NOTARY_KEY_PATH:?}" --key-id "$NOTARY_KEY_ID" --issuer "${NOTARY_ISSUER:?}")
else
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi

log "Notarizing $(basename "$FILE") (a few minutes)"
OUT="$(xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --timeout 45m --output-format json)" || {
  echo "$OUT" >&2
  die "notarytool failed. One-time setup: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you> --team-id <team>"
}
STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$OUT")"
ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' <<<"$OUT")"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  die "Notarization $STATUS."
fi
xcrun stapler staple -q "$FILE"
log "Notarized and stapled"
