#!/bin/bash
# Build from this checkout and install it locally (for testing changes before a release).
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_IDENTITY="${SIGN_IDENTITY:-Puck Bridge Signing}" scripts/build.sh "${1:-}"
DEST="/Applications"; [ -w "$DEST" ] || DEST="$HOME/Applications"
pkill -x PuckBridge 2>/dev/null || true
rm -rf "$DEST/Puck Bridge.app"; cp -R "build/Puck Bridge.app" "$DEST/"
launchctl bootout "gui/$(id -u)/ai.autonomous.harness.harnessd" 2>/dev/null || true
open "$DEST/Puck Bridge.app"
