#!/bin/bash
# Creates a local self-signed code-signing identity for DPI Peek.
#
# Why: TCC (privacy permissions) identifies an ad-hoc signed app by the hash of the
# binary, so every rebuild looks like a brand new app and "輸入監控" has to be granted
# again. Signing with a stable certificate gives the app one permanent identity.
#
# The identity lives in its own keychain inside this folder (password: dpipeek).
set -euo pipefail
cd "$(dirname "$0")"

KC="$(pwd)/signing/KizakiWorks.keychain"
KCPASS="dpipeek"
IDENTITY="KizakiWorks Local"

if [ -f "$KC" ]; then
    echo "==> identity keychain already exists: $KC"
    security find-identity -v -p codesigning "$KC" || true
    exit 0
fi

mkdir -p signing
echo "==> generating self-signed certificate"
cat > signing/openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = KizakiWorks Local
O = Local Development
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout signing/key.pem -out signing/cert.pem -config signing/openssl.cnf >/dev/null 2>&1

openssl pkcs12 -export -inkey signing/key.pem -in signing/cert.pem \
    -out signing/identity.p12 -passout pass:"$KCPASS" -name "$IDENTITY" >/dev/null 2>&1

echo "==> creating keychain $KC"
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import signing/identity.p12 -k "$KC" -P "$KCPASS" -A -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

echo "==> done. codesigning identities:"
security find-identity -v -p codesigning "$KC"
