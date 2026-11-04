#!/bin/bash
#
# Creates a free, self-signed code-signing identity for NTFS RW.
#
# Why: macOS ties Full Disk Access to an app's code signature. Ad-hoc signed builds
# get a new identity every build, so users lose Full Disk Access on each update.
# Signing every build with the same certificate keeps it.
#
# The identity lives in its own keychain OUTSIDE the repository:
#   ~/.ntfsrw-signing/signing.keychain-db   keychain with certificate + private key
#   ~/.ntfsrw-signing/password              keychain password (random)
#   ~/.ntfsrw-signing/identity.p12          backup (password in identity.p12.password)
#   ~/.ntfsrw-signing/certificate.pem       public certificate
#
# Back this folder up. If it is lost, the next build gets a new identity and users
# must re-enable Full Disk Access once. It does not change any macOS trust settings,
# and it does not remove Gatekeeper's warning (that needs an Apple Developer ID).
#
set -euo pipefail

CN="NTFS RW Code Signing (Pamdai)"
DIR="${SIGNING_DIR:-$HOME/.ntfsrw-signing}"
KC="$DIR/signing.keychain-db"
OPENSSL=/usr/bin/openssl   # LibreSSL writes .p12 files that `security import` accepts

if [ -f "$KC" ]; then
    echo "Signing identity already exists in $DIR — nothing to do."
    exit 0
fi

umask 077
mkdir -p "$DIR"
WORK="$(mktemp -d "$DIR/.work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
O = Pamdai
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating certificate \"$CN\" (valid 20 years)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 \
    -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$DIR/certificate.pem" 2>/dev/null

P12_PW="$("$OPENSSL" rand -hex 16)"
KC_PW="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$DIR/certificate.pem" \
    -name "$CN" -out "$DIR/identity.p12" -passout "pass:$P12_PW"
printf '%s' "$P12_PW" > "$DIR/identity.p12.password"
printf '%s' "$KC_PW" > "$DIR/password"

echo "==> Creating keychain $KC"
security create-keychain -p "$KC_PW" "$KC"
security set-keychain-settings "$KC"            # never auto-lock
security unlock-keychain -p "$KC_PW" "$KC"
security import "$DIR/identity.p12" -k "$KC" -P "$P12_PW" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC" >/dev/null

# create-keychain may add the keychain to the user's search list; keep that list unchanged.
CURRENT="$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//' | grep -vF "$KC" || true)"
if [ -n "$CURRENT" ]; then
    printf '%s\n' "$CURRENT" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
fi

chmod 700 "$DIR"; chmod 600 "$DIR"/*
echo "==> Done. Certificate SHA-1: $("$OPENSSL" x509 -in "$DIR/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
echo "    build.sh will now sign NTFS RW with \"$CN\"."
