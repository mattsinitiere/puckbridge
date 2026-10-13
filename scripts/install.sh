#!/bin/bash
# Install or update Puck Bridge from the latest GitHub release. Run on any of your Macs:
#   curl -fsSL https://raw.githubusercontent.com/mattsinitiere/puckbridge/main/scripts/install.sh | bash
set -euo pipefail
REPO="${PB_REPO:-mattsinitiere/puckbridge}"   # <- set once to your GitHub "username/repo"

echo "→ Finding the latest Puck Bridge release in $REPO…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*PuckBridge.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')"
[ -n "$URL" ] || { echo "No PuckBridge.zip found in the latest release of $REPO"; exit 1; }

TMP="$(mktemp -d)"
curl -fsSL "$URL" -o "$TMP/PuckBridge.zip"
ditto -x -k "$TMP/PuckBridge.zip" "$TMP"

DEST="/Applications"; [ -w "$DEST" ] || DEST="$HOME/Applications"; mkdir -p "$DEST"
pkill -x PuckBridge 2>/dev/null || true
rm -rf "$DEST/Puck Bridge.app"
mv "$TMP/Puck Bridge.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/Puck Bridge.app" 2>/dev/null || true
rm -rf "$TMP"

# Free the puck from OpenHarness's background service (the app keeps it free afterwards).
launchctl bootout "gui/$(id -u)/ai.autonomous.harness.harnessd" 2>/dev/null || true

open "$DEST/Puck Bridge.app"
echo "✓ Installed $(defaults read "$DEST/Puck Bridge.app/Contents/Info" CFBundleShortVersionString) to $DEST"
echo "  Approve Accessibility + Speech Recognition if asked, then ◎ menu → Start at login."
