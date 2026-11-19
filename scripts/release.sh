#!/bin/bash
# Cut a release: build → sign → DMG → notarize → Sparkle appcast → GitHub release.
# Usage: scripts/release.sh <version> [--dry-run]
#   --dry-run   build, sign and package everything, but skip notarization and publishing.
source "$(dirname "$0")/lib.sh"

VERSION="${1:?usage: release.sh <version> [--dry-run]}"
VERSION="${VERSION#v}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
cd "$ROOT"

if [ "$DRY_RUN" = 0 ]; then
  if [ -z "${CI:-}" ]; then
    [ -z "$(git status --porcelain)" ] || die "Commit or stash your changes first."
    git fetch -q origin
    [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{u}' 2>/dev/null || echo none)" ] || die "Push your branch first (HEAD must match its upstream)."
  fi
  git fetch -q --tags origin
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "Tag v$VERSION already exists."
  command -v gh >/dev/null || die "Install the GitHub CLI (gh)."
fi

BUILD="$(git rev-list --count HEAD)"
"$ROOT/scripts/build-release.sh" "$VERSION" "$BUILD"
DMG="$("$ROOT/scripts/make-dmg.sh" "$VERSION" | tail -1)"

if [ "$DRY_RUN" = 1 ]; then
  warn "Dry run: skipping notarization."
else
  "$ROOT/scripts/notarize.sh" "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

"$ROOT/scripts/appcast.sh" "$VERSION" "$BUILD" "$DMG"

if [ "$DRY_RUN" = 1 ]; then
  log "Dry run done: $DMG and $DIST/appcast.xml (not notarized, not published)"
  exit 0
fi

log "Publishing v$VERSION on GitHub"
gh release create "v$VERSION" "$DMG" "$DIST/appcast.xml" \
  --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "$APP_NAME $VERSION" --generate-notes
git fetch -q --tags origin
log "Released: https://github.com/$REPO/releases/tag/v$VERSION"
