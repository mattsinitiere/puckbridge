#!/bin/bash
# Build "Puck Bridge.app" (universal: Apple silicon + Intel).
#   scripts/build.sh [version]          -> build/Puck Bridge.app  and  dist/PuckBridge.zip
# Env: SIGN_IDENTITY  code-signing identity name (default: ad-hoc "-")
#      PB_REPO        "owner/repo" for in-app updates (default: from GITHUB_REPOSITORY or git remote)
#      PB_CHANNEL     branch a preview build comes from (empty = a release); PB_COMMIT its commit
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"; fi
VERSION="${VERSION#v}"
REPO="${PB_REPO:-${GITHUB_REPOSITORY:-}}"
if [ -z "$REPO" ]; then
  REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
fi
IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Puck Bridge.app"

echo "→ Building Puck Bridge $VERSION (updates from: ${REPO:-none})"
rm -rf build dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

FRAMEWORKS=(-framework Cocoa -framework SwiftUI -framework Speech -framework AVFoundation -framework ServiceManagement -framework ImageIO -framework UniformTypeIdentifiers)
swiftc -O -target arm64-apple-macos14  -o build/PuckBridge-arm64  Sources/main.swift "${FRAMEWORKS[@]}"
swiftc -O -target x86_64-apple-macos14 -o build/PuckBridge-x86_64 Sources/main.swift "${FRAMEWORKS[@]}"
lipo -create build/PuckBridge-arm64 build/PuckBridge-x86_64 -output "$APP/Contents/MacOS/PuckBridge"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: Resources/AppIcon.png (1024×1024, drawn from AppIcon.svg) -> AppIcon.icns
ICONSET="build/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PBUpdateRepo $REPO" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PBChannel ${PB_CHANNEL:-}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PBCommit ${PB_COMMIT:-}" "$APP/Contents/Info.plist"

if ! codesign --force --timestamp=none --sign "$IDENTITY" --identifier dev.sinitiere.puckbridge "$APP" 2>/dev/null; then
  echo "  (signing with '$IDENTITY' failed — falling back to ad-hoc)"
  codesign --force --sign - --identifier dev.sinitiere.puckbridge "$APP"
fi
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true

ditto -c -k --keepParent "$APP" dist/PuckBridge.zip
echo "✓ $APP"
echo "✓ dist/PuckBridge.zip"
