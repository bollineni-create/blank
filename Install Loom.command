#!/bin/zsh
# Double-click this in Finder to build Loom and install it in /Applications, with iCloud sync on.
# It runs scripts/install-mac.sh, which signs with the project's team so the Mac shares one library
# with the iPhone. Double-click it again after pulling changes to update the installed app.
cd "$(dirname "$0")"

if ./scripts/install-mac.sh; then
  echo
  echo "Loom is installed. From now on, open it from the Dock, Launchpad or Spotlight."
  echo "You can close this window."
else
  echo
  echo "The install didn't finish. The messages above say why."
  echo "If it's about signing: open Loom.xcodeproj once, pick your team under Signing & Capabilities, then try again."
  echo "Press Return to close this window."
  read
fi
