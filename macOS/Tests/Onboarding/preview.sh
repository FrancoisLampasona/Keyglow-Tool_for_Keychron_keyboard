#!/bin/sh
# Draws the setup guide into PNG files (synthetic states, no hardware, no permissions).
# usage: sh macOS/Tests/Onboarding/preview.sh [output-folder] [width height] [--all-languages]
set -eu
cd "$(dirname "$0")/../../.."
out="${1:-$PWD/build/ui-preview/onboarding}"
[ $# -gt 0 ] && shift
folder="$PWD/build/ui-preview/onboarding-tool"
mkdir -p "$folder" build/swift-cache
sources=$(ls macOS/Sources/*.swift | grep -v '/main.swift$')
xcrun swiftc -swift-version 6 -D KEYGLOW_UI_PREVIEW -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework CryptoKit -framework CoreBluetooth -framework Security -framework LocalAuthentication -framework ServiceManagement -framework UserNotifications \
  $sources macOS/Tests/Onboarding/OnboardingPreview.swift -o "$folder/onboarding-preview"
# The catalog is looked up beside the executable.
cp macOS/Resources/Localization.json "$folder/"
"$folder/onboarding-preview" "$out" "$@"
