#!/usr/bin/env bash
# One-line install for Claude Switcher:
#   curl -fsSL https://raw.githubusercontent.com/pein1625/claude-account-switcher/main/scripts/install.sh | bash
#
# Downloads the release .dmg with curl - which, unlike a browser, AirDrop or Slack, sets no quarantine flag,
# so Gatekeeper never shows the "Apple could not verify" dialog for this ad-hoc signed app - copies the app
# to /Applications (or ~/Applications) and opens it.
#   CLAUDE_SWITCHER_VERSION=0.2.0   pick a version instead of the latest release
#   DEST=~/Applications             install somewhere else
set -euo pipefail

REPO="pein1625/claude-account-switcher"
VERSION="${CLAUDE_SWITCHER_VERSION:-latest}"
DEST="${DEST:-/Applications}"
APP="ClaudeSwitcher.app"

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || { echo "Claude Switcher needs macOS 14 or newer (this is $(sw_vers -productVersion))" >&2; exit 1; }

if [ "$VERSION" = latest ]; then
  api="https://api.github.com/repos/$REPO/releases/latest"
else
  api="https://api.github.com/repos/$REPO/releases/tags/v$VERSION"
fi
url=$(curl -fsSL "$api" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed -E 's/.*"(https[^"]*)"$/\1/')
[ -n "$url" ] || { echo "no .dmg asset found at $api" >&2; exit 1; }

tmp=$(mktemp -d)
mnt=""
cleanup() { [ -n "$mnt" ] && hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

echo "downloading ${url##*/}"
curl -fL --progress-bar -o "$tmp/cs.dmg" "$url"
mnt=$(hdiutil attach -nobrowse -readonly "$tmp/cs.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
[ -d "$mnt/$APP" ] || { echo "image has no $APP" >&2; exit 1; }

if ! mkdir -p "$DEST" 2>/dev/null || [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"; mkdir -p "$DEST"
  echo "no write access to /Applications, installing to $DEST"
fi
pkill -x ClaudeSwitcher 2>/dev/null && sleep 1 || true
rm -rf "$DEST/$APP"
cp -R "$mnt/$APP" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
hdiutil detach "$mnt" -quiet; mnt=""

open "$DEST/$APP"
echo
echo "installed $DEST/$APP"
echo "Look for the icon on the menu bar (next to the clock). Answer 'Cài' in its first dialog, then open a new"
echo "terminal: 'claude' now runs through claude-as and hops accounts by itself when the 5h quota is gone."
