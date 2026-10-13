#!/bin/bash
# One-time setup so macOS keeps Puck Bridge's permissions (Accessibility, Speech Recognition) across updates.
#
# Makes a private "Puck Bridge Signing" code-signing certificate and hands it to GitHub as two repository
# secrets, so every build CI makes is signed with the same identity. Run it on your Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/mattsinitiere/puckbridge/main/scripts/make-signing-cert.sh | bash
#
# It copies each secret to the clipboard in turn and opens the GitHub page to paste it into. The private key only
# ever exists in a temporary folder that is deleted at the end (and in GitHub's encrypted secrets).
#
#   scripts/make-signing-cert.sh --out DIR   (CI self-test) write cert.p12.b64 and password to DIR, no prompts
set -euo pipefail

REPO="${PB_REPO:-mattsinitiere/puckbridge}"
NAME="Puck Bridge Signing"
OUT=""
if [ "${1:-}" = "--out" ]; then OUT="${2:?--out needs a folder}"; fi

# macOS's own /usr/bin/openssl (LibreSSL) writes .p12 files that `security import` reads; Homebrew's OpenSSL 3
# doesn't by default, so it is not used even if it comes first on PATH.
SSL=/usr/bin/openssl
[ -x "$SSL" ] || SSL="$(command -v openssl)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
"$SSL" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 7300 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASSWORD="$("$SSL" rand -hex 16)"
"$SSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/cert.p12" -passout "pass:$PASSWORD"
P12_B64="$(base64 < "$WORK/cert.p12" | tr -d '\n')"

if [ -n "$OUT" ]; then
  mkdir -p "$OUT"
  printf '%s' "$P12_B64" > "$OUT/cert.p12.b64"
  printf '%s' "$PASSWORD" > "$OUT/password"
  echo "✓ Wrote a throwaway \"$NAME\" certificate to $OUT"
  exit 0
fi

SECRETS="https://github.com/$REPO/settings/secrets/actions/new"
pause() { read -r -p "$1" _ < /dev/tty; }

echo
echo "Made a new \"$NAME\" certificate (valid 20 years)."
echo
echo "Step 1 of 2: the certificate"
printf '%s' "$P12_B64" | pbcopy
echo "  It's on your clipboard. GitHub opens in your browser:"
echo "    Name:   SIGNING_CERT_P12"
echo "    Secret: paste (⌘V), then click Add secret."
open "$SECRETS"
pause "  Press Return here when it's saved… "
echo
echo "Step 2 of 2: its password"
printf '%s' "$PASSWORD" | pbcopy
echo "  It's on your clipboard. On GitHub, click New repository secret:"
echo "    Name:   SIGNING_CERT_PASSWORD"
echo "    Secret: paste (⌘V), then click Add secret."
open "$SECRETS"
pause "  Press Return here when it's saved… "
printf '' | pbcopy
echo
echo "✓ Done. From the next build on, Puck Bridge is signed as \"$NAME\"."
echo "  macOS will ask for permissions one last time after that update, then remember them."
echo "  (If you ever run this again, the certificate changes and macOS asks once more.)"
