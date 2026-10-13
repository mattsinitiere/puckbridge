#!/bin/bash
# CI only: put the signing certificate from $SIGNING_CERT_P12 (base64 .p12) / $SIGNING_CERT_PASSWORD into a
# temporary keychain, trust it for code signing, and export SIGN_IDENTITY for scripts/build.sh.
# No certificate: does nothing, and the build is ad-hoc signed.
set -euo pipefail
NAME="Puck Bridge Signing"
if [ -z "${SIGNING_CERT_P12:-}" ]; then
  echo "No signing certificate: building ad-hoc signed (macOS will re-ask for permissions after updating)."
  exit 0
fi
KC="$RUNNER_TEMP/puckbridge.keychain-db"
KC_PW="$(uuidgen)"
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KC_PW" "$KC"
echo "$SIGNING_CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
security import "$RUNNER_TEMP/cert.p12" -k "$KC" -P "${SIGNING_CERT_PASSWORD:-}" -T /usr/bin/codesign
rm -f "$RUNNER_TEMP/cert.p12"
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null
# A self-signed certificate must be trusted for code signing before codesign will use it.
security find-certificate -c "$NAME" -p "$KC" > "$RUNNER_TEMP/cert.pem"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain "$RUNNER_TEMP/cert.pem"
security find-identity -v -p codesigning "$KC"
echo "SIGN_IDENTITY=$NAME" >> "$GITHUB_ENV"
