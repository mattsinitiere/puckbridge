#!/bin/bash
# Test Puck Bridge's puck firmware on this computer, without the puck or ESP-IDF: the upstream OpenHarness firmware
# at firmware/UPSTREAM plus firmware/patches, run in the host simulator (firmware/sim: the real UI and cable code,
# stubbed FreeRTOS/ESP-IDF). Every firmware/sim/demo/*.sim script must pass. Needs git, cc and python3.
#   scripts/test-firmware.sh            (CI runs it on Ubuntu; logs and screenshots land in firmware/sim/out)
set -euo pipefail
cd "$(dirname "$0")/.."
UPSTREAM="$(tr -d '[:space:]' < firmware/UPSTREAM)"
WORK="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/puckbridge-firmware-sim"
rm -rf "$WORK" && git init -q "$WORK"
git -C "$WORK" remote add origin https://github.com/autonomous-ai/openharness.git
git -C "$WORK" sparse-checkout set devices/harness-device/firmware
git -C "$WORK" fetch -q --depth 1 --filter=blob:none origin "$UPSTREAM"
git -C "$WORK" checkout -q FETCH_HEAD
for p in firmware/patches/*.patch; do git -C "$WORK" apply --whitespace=nowarn "$PWD/$p"; done
SANITIZE="${SANITIZE-1}" FW="$WORK/devices/harness-device/firmware" firmware/sim/test.sh
