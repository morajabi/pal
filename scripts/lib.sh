# Shared settings for Pal's build and release scripts. Source it; don't run it.
# Everything here can be overridden with environment variables.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Pal"
REPO="${PAL_REPO:-morajabi/pal}"
DIST="${PAL_DIST:-$ROOT/dist}"
DERIVED="$ROOT/build/release"
SIGN_IDENTITY="${PAL_SIGN_IDENTITY:-Developer ID Application}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-pal}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pal-notary}"
MIN_MACOS="26.0"

log()  { printf '\033[1;34m▸\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Apple team: $PAL_TEAM_ID, else Config/Local.xcconfig.
team_id() {
  if [ -n "${PAL_TEAM_ID:-}" ]; then echo "$PAL_TEAM_ID"; return; fi
  local f="$ROOT/Config/Local.xcconfig"
  [ -f "$f" ] && sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$f" | head -1
}

# Sparkle's CLI tools ship inside the Swift package.
sparkle_bin() {
  local dir
  for dir in "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin" "$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
    [ -x "$dir/sign_update" ] && { echo "$dir"; return; }
  done
  die "Sparkle tools not found. Build once (scripts/build-release.sh) so the package is fetched."
}
