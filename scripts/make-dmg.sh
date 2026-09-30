#!/bin/zsh
# Wraps a signed, notarized Tessera.app in the installer disk image: the app, a link to
# /Applications and the branded window (assets/dmg). The image is signed with the Developer ID,
# notarized and stapled too, so it opens without a Gatekeeper warning even offline.
# usage: scripts/make-dmg.sh <path/to/Tessera.app> <out.dmg>
set -euo pipefail
repo=${0:A:h}/..
app=${1:?usage: make-dmg.sh <Tessera.app> <out.dmg>}
out=${2:?usage: make-dmg.sh <Tessera.app> <out.dmg>}
app=${app:A}
out=${out:A}
profile=${TESSERA_NOTARY_PROFILE:-tessera-notary}
identity=${TESSERA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[[ -n $identity ]] || { echo "no Developer ID Application identity: the image must be signed" >&2; exit 1; }
xcrun stapler validate $app >/dev/null || { echo "$app is not stapled: notarize the app first" >&2; exit 1; }

# dmgbuild ≥ 1.6.7 writes the background as a bookmark; the legacy alias of 1.6.5 does not
# resolve on macOS 26 and Finder falls back to grey. It needs Python ≥ 3.10.
venv=$repo/.build/dmg-venv
if ! $venv/bin/python -c 'import importlib.metadata as m, sys; sys.exit(tuple(map(int, m.version("dmgbuild").split(".")[:3])) < (1, 6, 7))' 2>/dev/null; then
  python=$(for v in 3.13 3.12 3.11 3.10; do command -v python$v && break; done | head -1)
  [[ -n $python ]] || { echo "dmgbuild needs Python 3.10 or later" >&2; exit 1; }
  rm -rf $venv
  $python -m venv $venv
  $venv/bin/pip install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
fi

rm -f $out
$venv/bin/dmgbuild -s $repo/scripts/dmg-settings.py \
  -D app=$app -D background=$repo/assets/dmg/background.tiff -D icon=$repo/assets/brand/AppIcon.icns \
  Tessera $out
codesign --force --timestamp --sign "$identity" $out
xcrun notarytool submit $out --keychain-profile "$profile" --wait
xcrun stapler staple $out
spctl --assess --type open --context context:primary-signature --verbose=2 $out
