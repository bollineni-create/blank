#!/bin/zsh
# Double-click this in Finder to get the latest Loom from GitHub, build it and install it in /Applications,
# with iCloud sync on. Double-click it again any time to update.
#
# It always installs the latest main. Nothing on this Mac is thrown away: edits are put aside in a git stash
# and commits that aren't on GitHub are kept on a backup branch. If it can't reach GitHub, it says so and
# installs the copy that's here.

# Braces: zsh reads the whole script before running it, so the update can safely replace this file.
{
cd "$(dirname "$0")"

update() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "This folder wasn't downloaded with git, so it can't update itself. Installing the copy that's here."
    echo "To get updates automatically, download Loom with:  git clone https://github.com/bollineni-create/blank.git"
    return
  fi

  echo "Getting the latest Loom from GitHub…"
  if ! git fetch --quiet origin main; then
    echo "Couldn't reach GitHub, so this installs the copy that's here. Double-click again when you're online to update."
    return
  fi

  if [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" && -z "$(git status --porcelain)" ]]; then
    echo "Already up to date."
    return
  fi

  local stamp=$(date +%Y-%m-%d-%H%M%S)
  if [[ -n "$(git status --porcelain)" ]]; then
    git stash push --quiet --include-untracked -m "Install Loom: edits put aside on $stamp"
    echo "Put aside edits made on this Mac (get them back with: git stash pop)."
  fi
  if [[ "$(git rev-list --count origin/main..HEAD)" -gt 0 ]]; then
    git branch "loom-backup-$stamp" HEAD
    echo "Kept commits that aren't on GitHub on the branch loom-backup-$stamp."
  fi
  if git checkout --quiet -B main --track origin/main; then
    echo "Updated to the latest Loom: $(git log -1 --format=%s)"
  else
    echo "Couldn't switch to the latest Loom, so this installs the copy that's here."
  fi
}

update
echo

if ./scripts/install-mac.sh; then
  echo
  echo "Loom is installed. From now on, open it from the Dock, Launchpad or Spotlight."
  echo "To update, double-click Install Loom again. You can close this window."
else
  echo
  echo "The install didn't finish. The messages above say why."
  echo "If it's about signing: open Loom.xcodeproj once, pick your team under Signing & Capabilities, then try again."
  echo "Press Return to close this window."
  read
fi
exit
}
