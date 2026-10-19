#!/bin/zsh
# Builds Loom for the Mac and installs it in /Applications, so it opens from the Dock, Launchpad or Spotlight.
#
#   ./scripts/install-mac.sh               build, install into /Applications and open it
#   ./scripts/install-mac.sh --no-install  build only (into build/)
#
# Needs Xcode. The build is ad-hoc signed, so no Apple ID or team is needed; on another Mac, right-click
# and choose Open the first time. Run it again after pulling changes to update the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

xcodebuild -project Loom.xcodeproj -scheme Loom-macOS -configuration Release \
  -derivedDataPath "$ROOT/build" -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -quiet build

APP="$ROOT/build/Build/Products/Release/Loom.app"
echo "Built $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x Loom 2>/dev/null || true
  rm -rf /Applications/Loom.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Loom.app"
  open /Applications/Loom.app
fi
