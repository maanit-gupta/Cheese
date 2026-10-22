#!/bin/zsh
# Builds a Release Cheese.app and zips it for GitHub Releases.
#
#   scripts/package.sh            -> dist/Cheese.zip (+ .sha256)
#
# The zip keeps a stable name so https://github.com/maanit-gupta/Cheese/releases/latest/download/Cheese.zip
# always points at the newest build. The app is signed with the Apple Development identity from
# project.yml and is not notarized; see docs/INSTALL.md for the first-launch Gatekeeper step.
set -euo pipefail

cd "${0:A:h}/.."

DERIVED=build/ReleaseData
APP="$DERIVED/Build/Products/Release/Cheese.app"
DIST=dist

xcodegen generate
xcodebuild -project Cheese.xcodeproj -scheme Cheese -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build

codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

rm -rf "$DIST"
mkdir -p "$DIST"
# ditto keeps symlinks, extended attributes and the code signature intact; plain `zip` can break them.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Cheese.zip"
(cd "$DIST" && shasum -a 256 Cheese.zip > Cheese.zip.sha256)

echo
echo "Cheese $VERSION packaged:"
ls -lh "$DIST"
cat "$DIST/Cheese.zip.sha256"
