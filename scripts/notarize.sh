#!/bin/zsh
# Notarize and staple the Developer ID disk image built by package-dmg.py.
# usage: zsh scripts/notarize.sh <notarytool-keychain-profile>
# The profile is created once by the developer with
#   xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
# which asks for an app-specific password. This script never reads or prints it.
set -euo pipefail
cd "${0:A:h:h}"
profile="${1:?usage: zsh scripts/notarize.sh <notarytool-keychain-profile>}"
dmg=$(ls dist/Keyglow-*-macOS-arm64.dmg | tail -1)
codesign --verify --strict "$dmg"
# Uploads the image to Apple's notary service and waits for the verdict.
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl -a -vv -t open --context context:primary-signature "$dmg"
# Stapling changes the file: publish the checksum computed afterwards.
(cd dist && shasum -a 256 "${dmg:t}") > "$dmg.sha256"
cat "$dmg.sha256"
