#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
project="$PWD"
# Build in a new bundle. Failed compilation/signing never damages the previous app.
mkdir -p build/swift-cache dist
stage="$(mktemp -d "$project/build/keyglow-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Keyglow.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -swift-version 6 -O -module-cache-path "$project/build/swift-cache" \
  -target "${TARGET_ARCH:-arm64}-apple-macos13.0" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework CryptoKit \
  macOS/Sources/*.swift -o "$bundle/Contents/MacOS/Keyglow"
cp macOS/Assets/Keyglow.icns "$bundle/Contents/Resources/"
cp macOS/Assets/TastieraIcon.png "$bundle/Contents/Resources/"
# A known build identity, not a live device capability report.
manifest="${FIRMWARE_MANIFEST:-firmware/verified-builds/rgb-v06.json}"
cp "$manifest" "$bundle/Contents/Resources/firmware-manifest.json"
cp macOS/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
# Retain a recoverable previous build outside the public distribution.
if [[ -e dist/Keyglow.app ]]; then
  previous="$(mktemp -d "$project/build/keyglow-previous.XXXXXX")"
  mv dist/Keyglow.app "$previous/Keyglow.app"
fi
mv "$bundle" dist/Keyglow.app
printf '%s\n' "$project/dist/Keyglow.app"
