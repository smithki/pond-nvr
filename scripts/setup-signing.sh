#!/bin/sh
# Creates "Pond Local Signing", a self-signed code-signing certificate in your login keychain, once per Mac.
# make build and make app sign with it when it is there. The Keychain then knows each rebuild as the same
# program, so "Always Allow" for the camera passwords and the HomeKit record holds across rebuilds (ad hoc
# signing gives every build a new identity, and the Keychain asks again).
#
# The key never leaves this Mac and is not in the repo. Only codesign may use it. To remove it:
#   security delete-identity -c "Pond Local Signing"
set -eu
NAME="Pond Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

[ "$(uname -s)" = Darwin ] || { echo "Code signing is for macOS; nothing to do on $(uname -s)."; exit 0; }
if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "✓ $NAME is already in your login keychain"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
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
CNF
# macOS's own openssl (LibreSSL): its PKCS#12 encryption is the kind security import reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout "pass:$PASS" -out "$WORK/identity.p12"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "✓ $NAME added to your login keychain"
echo "  The first build signed with it asks once more for each Keychain item; choose Always Allow."
