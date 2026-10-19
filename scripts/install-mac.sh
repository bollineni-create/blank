#!/bin/zsh
# Builds Loom for the Mac and installs it in /Applications, so it opens from the Dock, Launchpad or Spotlight.
#
#   ./scripts/install-mac.sh                          build, install into /Applications and open it
#   ./scripts/install-mac.sh --no-install             build only (into build/)
#   LOOM_TEAM=ABCDE12345 ./scripts/install-mac.sh     sign with your paid team and turn on iCloud sync
#
# Needs Xcode. Without LOOM_TEAM the build is ad-hoc signed: no Apple ID needed, but no iCloud, so it keeps
# its own library. With LOOM_TEAM (your Apple Developer Program team ID) it signs with that team and the
# iCloud entitlements, so it shares one library with the iPhone app signed by the same team.
# Run it again after pulling changes to update the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

if [[ -n "${LOOM_TEAM:-}" ]]; then
  SIGNING=(-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$LOOM_TEAM"
           CODE_SIGN_ENTITLEMENTS=Loom/Resources/Loom-macOS-iCloud.entitlements)
else
  SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
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
