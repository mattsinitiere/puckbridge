#!/bin/bash
# Build Puck Bridge's puck firmware: the upstream OpenHarness firmware at the commit in firmware/UPSTREAM, plus
# firmware/patches/*.patch (applied in order).
#   scripts/build-firmware.sh   -> firmware/out/PuckFirmware.bin + firmware/out/PuckFirmware.json
# Needs git and docker (espressif/idf:v5.5, the ESP-IDF the firmware pins). CI runs it on Ubuntu; the app bundles
# the result and installs it over the USB cable (Settings → Puck → Firmware).
set -euo pipefail
cd "$(dirname "$0")/.."
IDF_IMAGE="${IDF_IMAGE:-espressif/idf:v5.5}"
UPSTREAM="$(tr -d '[:space:]' < firmware/UPSTREAM)"
OUT="$PWD/firmware/out"
rm -rf "$OUT" && mkdir -p "$OUT"

shopt -s nullglob
PATCHES=(firmware/patches/*.patch)
if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "No firmware patches: nothing to build (the app ships without bundled firmware)."
  exit 0
fi

WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/puckbridge-firmware"
rm -rf "$WORK" && git init -q "$WORK"
git -C "$WORK" remote add origin https://github.com/autonomous-ai/openharness.git
git -C "$WORK" sparse-checkout set devices/harness-device/firmware
git -C "$WORK" fetch -q --depth 1 --filter=blob:none origin "$UPSTREAM"
git -C "$WORK" checkout -q FETCH_HEAD
for p in "${PATCHES[@]}"; do
  echo "→ applying $p"
  git -C "$WORK" apply --whitespace=nowarn "$PWD/$p"
done

FW="$WORK/devices/harness-device/firmware"
VERSION="$(tr -d '[:space:]' < "$FW/version.txt")"
echo "→ building firmware $VERSION ($IDF_IMAGE)"
docker run --rm -v "$FW:/project" -w /project -e HOME=/tmp "$IDF_IMAGE" idf.py build

BIN="$(ls "$FW"/build/*.bin | grep -v -e bootloader -e partition | head -1)"
cp "$BIN" "$OUT/PuckFirmware.bin"
SHA="$(sha256sum "$OUT/PuckFirmware.bin" | cut -d' ' -f1)"
SIZE="$(stat -c %s "$OUT/PuckFirmware.bin")"
printf '{"version":"%s","sha256":"%s","size":%s,"upstream":"%s"}\n' "$VERSION" "$SHA" "$SIZE" "$UPSTREAM" > "$OUT/PuckFirmware.json"
cat "$OUT/PuckFirmware.json"
echo "✓ $OUT/PuckFirmware.bin"
