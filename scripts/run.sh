#!/bin/zsh
# Build Pal and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Pal.xcodeproj -scheme Pal -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' build -quiet "$@"
pkill -f "Debug/Pal.app/Contents/MacOS/Pal" 2>/dev/null || true
sleep 0.3
open "build/Build/Products/Debug/Pal.app"
