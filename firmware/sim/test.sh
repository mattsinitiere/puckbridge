#!/usr/bin/env bash
# FW=<patched firmware dir> ./test.sh — build, then run every demo/*.sim; logs and PNGs land in out/. Exit status 1 if any `expect` failed.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
./build.sh || exit 1
mkdir -p out/renders
cp "$FW/test/vectors/pet_min.hpet" out/pet_min.hpet
status=0
for f in demo/*.sim; do
  log="out/$(basename "$f" .sim).log"
  if ./out/sim "$f" > "$log" 2>&1; then echo "ok    $f ($(grep -c '^PASS' "$log") checks) -> $log"
  else echo "FAIL  $f -> $log"; grep '^FAIL' "$log" | sed 's/^/      /'; status=1; fi
done
exit $status
