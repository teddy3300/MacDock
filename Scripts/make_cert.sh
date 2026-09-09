#!/bin/bash
# Create a stable self-signed code signing identity for MacDock.
# Run once per machine; required for TCC permissions to persist across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/certs
cd build/certs

IDENTITY="MacDock Development"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "identity already exists: $IDENTITY"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -keyout macdock.key -out macdock.crt -days 3650 -nodes \
  -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" >/dev/null 2>&1

openssl pkcs12 -export -out macdock.p12 -inkey macdock.key -in macdock.crt \
  -passout pass:macdock -legacy >/dev/null 2>&1

security import macdock.p12 -k ~/Library/Keychains/login.keychain-db -P macdock -T /usr/bin/codesign >/dev/null 2>&1
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db macdock.crt >/dev/null 2>&1

echo "identity ready: $IDENTITY"
