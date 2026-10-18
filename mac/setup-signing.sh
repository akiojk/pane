#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain.
# The private key stays on this Mac. Do not commit it.
# A stable signature is what lets macOS keep the Screen Recording grant across rebuilds.
set -euo pipefail

NAME="${PANE_SIGNING_IDENTITY:-Pane Local Signing}"
# find-identity -v hides this certificate: a private self-signed cert is "not trusted",
# and that is what codesign expects. Match the unfiltered list.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Signing certificate \"$NAME\" is already in the login keychain."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/cert.cnf" -extensions ext
# -legacy: OpenSSL 3's default PKCS12 uses a MAC that `security import` rejects.
openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
  -passout pass:pane -name "$NAME"
security import "$TMP/cert.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P pane -A -T /usr/bin/codesign -T /usr/bin/security

if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "The certificate was imported, but codesign cannot see \"$NAME\"." >&2
  exit 1
fi
echo "Created \"$NAME\" in the login keychain. Screen Recording stays granted across rebuilds on this Mac."
