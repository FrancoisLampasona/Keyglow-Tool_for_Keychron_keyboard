#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
project="$PWD"
# Build in a new bundle. Failed compilation/signing never damages the previous app.
mkdir -p build/swift-cache dist
stage="$(mktemp -d "$project/build/keyglow-app.XXXXXX")"
cleanup() {
  # Restore the original path if publishing the completed new bundle failed.
  if [[ -d "$stage/previous.bundle" && ! -e "$project/dist/Keyglow.app" ]]; then
    mv "$stage/previous.bundle" "$project/dist/Keyglow.app"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT
bundle="$stage/Keyglow.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -swift-version 6 -O -module-cache-path "$project/build/swift-cache" \
  -target "${TARGET_ARCH:-arm64}-apple-macos13.0" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework CryptoKit -framework CoreBluetooth -framework Security -framework LocalAuthentication \
  macOS/Sources/*.swift -o "$bundle/Contents/MacOS/Keyglow"
cp macOS/Assets/Keyglow.icns "$bundle/Contents/Resources/"
cp macOS/Assets/TastieraIcon.png "$bundle/Contents/Resources/"
# A known build identity, not a live device capability report.
manifest="${FIRMWARE_MANIFEST:-firmware/verified-builds/ota-v08.json}"
cp "$manifest" "$bundle/Contents/Resources/firmware-manifest.json"
# Optional public baseline and target contain application code only. Owner keys,
# personalized loaders and controller backups must never enter the bundle.
if [[ -n "${FIRMWARE_BASELINE:-}" ]]; then
  cp "$FIRMWARE_BASELINE" "$bundle/Contents/Resources/firmware-base.bin"
fi
if [[ -n "${FIRMWARE_UPDATE_PACKAGE:-}" ]]; then
  python3 firmware/ota/package.py verify "$FIRMWARE_UPDATE_PACKAGE" >/dev/null
  cp "$FIRMWARE_UPDATE_PACKAGE" "$bundle/Contents/Resources/firmware-update.kgfw"
fi
python3 scripts/bundle-bootstrap.py "$bundle"
cp -R macOS/Resources/. "$bundle/Contents/Resources/"
cp macOS/Info.plist "$bundle/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/"
python3 scripts/sign-app.py "$bundle"
# A configured certificate identity must survive future builds. Refuse a silent
# fallback to ad-hoc signing before replacing the working application.
python3 scripts/sign-app.py --verify-update dist/Keyglow.app "$bundle"
# Preserve a verified archive, not another discoverable .app in Launchpad.
if [[ -e dist/Keyglow.app ]]; then
  python3 scripts/clean-builds.py archive-current >/dev/null
  # Archiving may take time: check again if the app was reopened meanwhile.
  python3 scripts/sign-app.py --verify-update dist/Keyglow.app "$bundle"
  mv dist/Keyglow.app "$stage/previous.bundle"
fi
mv "$bundle" dist/Keyglow.app
printf '%s\n' "$project/dist/Keyglow.app"
