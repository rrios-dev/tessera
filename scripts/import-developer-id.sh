#!/bin/zsh
# Imports a Developer ID Application certificate downloaded from developer.apple.com together
# with the private key its request was made from, into the login keychain, so that
# scripts/install.sh can sign with it (audit B7).
#
# usage: scripts/import-developer-id.sh ~/Downloads/developerID_application.cer [DeveloperIDG2CA.cer]
#   The key is the one generated with the request, in
#   ~/Library/Application Support/Tessera-signing/developer-id.key (0600, never in the repo).
set -euo pipefail
cer=${1:?usage: import-developer-id.sh <developerID_application.cer> [DeveloperIDG2CA.cer]}
intermediate=${2:-}
dir="$HOME/Library/Application Support/Tessera-signing"
key="$dir/developer-id.key"
[[ -f $key ]] || { echo "no private key at $key" >&2; exit 1; }
keychain="$HOME/Library/Keychains/login.keychain-db"

work=$(mktemp -d)
trap 'rm -rf $work' EXIT
# The certificate must belong to this key: compare public keys.
openssl x509 -inform DER -in "$cer" -out $work/cert.pem 2>/dev/null || cp "$cer" $work/cert.pem
[[ $(openssl x509 -in $work/cert.pem -noout -pubkey | shasum) == $(openssl rsa -in "$key" -pubout 2>/dev/null | shasum) ]] \
  || { echo "this certificate was not issued for the key in $key" >&2; exit 1; }
openssl x509 -in $work/cert.pem -noout -subject

if [[ -n $intermediate ]]; then
  security import "$intermediate" -k "$keychain" 2>/dev/null || true
fi
# A one-off transport password: the bundle exists only in this temporary folder.
pass=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$key" -in $work/cert.pem -name "Tessera Developer ID" -out $work/id.p12 -passout pass:$pass 2>/dev/null \
  || openssl pkcs12 -export -inkey "$key" -in $work/cert.pem -name "Tessera Developer ID" -out $work/id.p12 -passout pass:$pass
security import $work/id.p12 -k "$keychain" -P "$pass" -T /usr/bin/codesign -T /usr/bin/security
echo "---"
security find-identity -v -p codesigning
