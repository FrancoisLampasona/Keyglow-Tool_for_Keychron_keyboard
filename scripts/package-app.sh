#!/bin/zsh
# Package only the self-contained app and its optional public application images.
# Never include profiles, owner keys, personalized loaders or research.
set -euo pipefail
cd "${0:A:h:h}"
bundle="$PWD/dist/Keyglow.app"
codesign --verify --strict "$bundle"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")
archive="$PWD/dist/Keyglow-${version}-macOS-arm64.zip"
ditto -c -k --keepParent --norsrc --noextattr "$bundle" "$archive"
(cd dist && shasum -a 256 "${archive:t}") > "$archive.sha256"
printf '%s\n' "$archive"
