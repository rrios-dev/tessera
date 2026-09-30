#!/bin/zsh
# Builds, signs and installs Tessera as an app and a login service (audit A3, B7):
#   /Applications/Tessera.app (or ~/Applications)  (LSUIElement, bundle id dev.rrios.tessera, version + git SHA)
#   ~/Library/LaunchAgents/dev.rrios.tessera.plist  (KeepAlive on crash, ThrottleInterval 5)
#   ~/.local/bin/tessera -> the app's binary (the CLI must be the signed binary: a signed engine
#                           accepts commands only from programs signed by the same team)
#
# Signing: the first "Developer ID Application" identity in the keychain, or $TESSERA_SIGN_IDENTITY;
# hardened runtime and a secure timestamp. Notarization when a notarytool keychain profile exists
# ($TESSERA_NOTARY_PROFILE, default "tessera-notary"), then the ticket is stapled. Without an
# identity it falls back to an ad hoc signature (Accessibility must then be re-granted after
# every install). The previous app is kept as Tessera.app.previous; --rollback restores it.
set -euo pipefail
repo=${0:A:h}/..
cd $repo
# /Applications when this user can write it (admins can), else ~/Applications.
if [[ -w /Applications ]]; then app=/Applications/Tessera.app; else app=$HOME/Applications/Tessera.app; fi
profile=${TESSERA_NOTARY_PROFILE:-tessera-notary}

if [[ ${1:-} == --rollback ]]; then
  [[ -d $app.previous ]] || { echo "no previous install to roll back to" >&2; exit 1; }
  rm -rf $app.failed && mv $app $app.failed && mv $app.previous $app
  $app/Contents/MacOS/tessera service install --binary $app/Contents/MacOS/tessera
  echo "rolled back; the failed build is at $app.failed"
  exit 0
fi

identity=${TESSERA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}

swift build -c release --product tessera
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/TesseraEngine/BuildInfo.swift)
sha=$(git rev-parse --short HEAD)$([[ -n $(git status --porcelain --untracked-files=no) ]] && echo "-dirty" || true)

work=$(mktemp -d)
staging=$work/Tessera.app
mkdir -p $staging/Contents/MacOS $staging/Contents/Resources
cp .build/release/tessera $staging/Contents/MacOS/tessera
cp assets/brand/AppIcon.icns $staging/Contents/Resources/AppIcon.icns
cat > $staging/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.rrios.tessera</string>
  <key>CFBundleName</key><string>Tessera</string>
  <key>CFBundleDisplayName</key><string>Tessera</string>
  <key>CFBundleExecutable</key><string>tessera</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$sha</string>
  <key>TesseraGitSHA</key><string>$sha</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

if [[ -n $identity ]]; then
  echo "signing with: $identity"
  codesign --force --options runtime --timestamp --sign "$identity" --identifier dev.rrios.tessera $staging
  codesign --verify --strict --verbose=2 $staging
  if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then
    echo "notarizing with profile '$profile' (this can take a few minutes)"
    ditto -c -k --keepParent $staging $work/Tessera.zip
    xcrun notarytool submit $work/Tessera.zip --keychain-profile "$profile" --wait
    xcrun stapler staple $staging
    spctl --assess --type execute --verbose=2 $staging
  else
    echo "notarization skipped: no notarytool profile '$profile' (see docs/RUNBOOK.md › Signing)."
  fi
else
  echo "no Developer ID Application identity found: signing ad hoc (Accessibility must be re-granted after each install)."
  codesign --force --sign - --identifier dev.rrios.tessera $staging
fi

# A hand-started engine would own the state directory: stop it, restoring its windows.
pkill -TERM -f 'tessera run$' 2>/dev/null && sleep 2 || true

mkdir -p ${app:h} $HOME/.local/bin
# An earlier install in the other location would leave a second Tessera around.
for other in /Applications/Tessera.app $HOME/Applications/Tessera.app; do
  [[ $other != $app && -d $other ]] && rm -rf $other $other.previous
done
if [[ -d $app ]]; then rm -rf $app.previous; mv $app $app.previous; fi
mv $staging $app
ln -sf $app/Contents/MacOS/tessera $HOME/.local/bin/tessera
$app/Contents/MacOS/tessera service install --binary $app/Contents/MacOS/tessera
echo "installed Tessera $version ($sha) at $app; CLI at ~/.local/bin/tessera"
codesign -dv $app 2>&1 | grep -E "Authority=Developer ID|TeamIdentifier|Timestamp" || true
echo "First time only: System Settings › Privacy & Security › Accessibility › allow Tessera."
