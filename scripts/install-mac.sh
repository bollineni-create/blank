#!/bin/zsh
# Builds Loom for the Mac and installs it in /Applications, so it opens from the Dock, Launchpad or Spotlight.
#
#   ./scripts/install-mac.sh                    build, install into /Applications and open it
#   ./scripts/install-mac.sh --no-install       build only (into build/)
#   LOOM_TEAM= ./scripts/install-mac.sh         ad-hoc signed, without iCloud
#
# Needs Xcode. It signs with the project's team (66BLLM3ERE, or LOOM_TEAM=<team id>) and the iCloud
# entitlements, so it shares one library with the iPhone app signed by the same team. An empty LOOM_TEAM
# builds ad-hoc signed instead: no Apple ID needed, but no iCloud, so it keeps its own library.
# Run it again after pulling changes to update the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

LOOM_TEAM="${LOOM_TEAM-66BLLM3ERE}"
if [[ -n "$LOOM_TEAM" ]]; then
  SIGNING=(-allowProvisioningUpdates DEVELOPMENT_TEAM="$LOOM_TEAM")
else
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
           CODE_SIGN_ENTITLEMENTS=Loom/Resources/Loom-macOS.entitlements)
fi

xcodebuild -project Loom.xcodeproj -scheme Loom-macOS -configuration Release \
  -derivedDataPath "$ROOT/build" -destination 'generic/platform=macOS' \
  "${SIGNING[@]}" -quiet build

APP="$ROOT/build/Build/Products/Release/Loom.app"
echo "Built $APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x Loom 2>/dev/null || true
  rm -rf /Applications/Loom.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Loom.app"
  open /Applications/Loom.app
fi
