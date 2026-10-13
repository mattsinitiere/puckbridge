#!/bin/bash
# The drag-to-Applications installer: dist/PuckBridge.dmg from build/Puck Bridge.app (run scripts/build.sh first).
# Needs macOS (hdiutil, tiffutil) and dmgbuild (`pip3 install dmgbuild`). Env: SIGN_IDENTITY to sign the dmg too.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Puck Bridge.app"
[ -d "$APP" ] || { echo "Build the app first (scripts/build.sh)"; exit 1; }
mkdir -p build dist
# One TIFF holding both resolutions, so the window is sharp on Retina screens.
tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png -out build/dmg-background.tiff
rm -f dist/PuckBridge.dmg
dmgbuild -s scripts/dmg_settings.py \
  -D app="$APP" -D background=build/dmg-background.tiff -D icon="$APP/Contents/Resources/AppIcon.icns" \
  "Puck Bridge" dist/PuckBridge.dmg
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" dist/PuckBridge.dmg || echo "  (couldn't sign the dmg; it still works)"
fi
hdiutil verify dist/PuckBridge.dmg >/dev/null
echo "✓ dist/PuckBridge.dmg ($(du -h dist/PuckBridge.dmg | cut -f1))"
