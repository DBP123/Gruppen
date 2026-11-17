#!/bin/bash
# Makes "Gruppen Local Signing", a self-signed code-signing certificate in your
# login keychain, for build.sh to sign with. Run once per Mac:
#
#   Tools/make-signing-identity.sh
#
# Why: macOS remembers permissions such as Accessibility against how an app is
# signed. Signed ad-hoc, every build is a different app to it, so every rebuild
# quietly loses the grant while System Settings still shows it switched on.
# Signed with this certificate, every build is the same app, and a grant stays.
#
# It is not an Apple Developer ID and changes nothing about Gatekeeper. The
# private key never leaves your keychain. To remove it: Keychain Access, login,
# My Certificates, delete "Gruppen Local Signing".
set -euo pipefail

NAME="${1:-Gruppen Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "\"$NAME\" already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF

# The system's LibreSSL on purpose: a Homebrew OpenSSL 3 writes PKCS#12 files
# that `security import` cannot read.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$WORK/cert.conf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# A throwaway password: the bundle exists only to carry the key into the keychain.
PASSWORD="$(uuidgen)"
/usr/bin/openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout "pass:$PASSWORD" \
    -out "$WORK/identity.p12"

# -T: codesign may use the key without asking every time. macOS may still ask
# once, the first time a build signs; choose "Always Allow".
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
    echo "Made \"$NAME\". build.sh will sign with it from now on."
    echo "Rebuild, then grant Accessibility once more: the new signature is a new identity to macOS,"
    echo "and the last one you will need to grant."
else
    echo "Imported, but codesign does not list \"$NAME\" as a signing identity." >&2
    echo "Open Keychain Access and check that it is in the login keychain with its private key." >&2
    exit 1
fi
