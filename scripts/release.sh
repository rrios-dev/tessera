#!/bin/zsh
# Builds a distributable Tessera: universal (arm64 + x86_64) when the toolchain can, signed with
# the Developer ID, notarized and stapled, zipped as dist/Tessera-<version>.zip and wrapped in the
# drag-to-Applications installer dist/Tessera.dmg (signed, notarized, stapled). Installs nothing.
# usage: scripts/release.sh
set -euo pipefail
repo=${0:A:h}/..
cd $repo
profile=${TESSERA_NOTARY_PROFILE:-tessera-notary}
identity=${TESSERA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[[ -n $identity ]] || { echo "no Developer ID Application identity: a release must be signed" >&2; exit 1; }
version=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/TesseraEngine/BuildInfo.swift)
sha=$(git rev-parse --short HEAD)

if swift build -c release --product tessera --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  binary=.build/apple/Products/Release/tessera
  archs="arm64 + x86_64"
else
  swift build -c release --product tessera
  binary=.build/release/tessera
  archs=$(uname -m)
fi

work=$(mktemp -d)
app=$work/Tessera.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $binary $app/Contents/MacOS/tessera
cp assets/brand/AppIcon.icns $app/Contents/Resources/AppIcon.icns
cat > $app/Contents/Info.plist <<PLIST
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
codesign --force --options runtime --timestamp --sign "$identity" --identifier dev.rrios.tessera $app
codesign --verify --strict $app
ditto -c -k --keepParent $app $work/submit.zip
xcrun notarytool submit $work/submit.zip --keychain-profile "$profile" --wait
xcrun stapler staple $app
spctl --assess --type execute --verbose=2 $app
mkdir -p dist
ditto -c -k --keepParent $app dist/Tessera-$version.zip
shasum -a 256 dist/Tessera-$version.zip | tee dist/Tessera-$version.zip.sha256
# Unversioned on purpose: /releases/latest/download/Tessera.dmg always points at the newest one.
scripts/make-dmg.sh $app dist/Tessera.dmg
shasum -a 256 dist/Tessera.dmg | tee dist/Tessera.dmg.sha256
echo "built dist/Tessera-$version.zip and dist/Tessera.dmg ($archs, $sha)"
