#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
folder="$PWD/build/ui-preview/Keyglow Install Preview.app"
mkdir -p "$folder/Contents/MacOS" build/swift-cache
xcrun swiftc -swift-version 6 -D KEYGLOW_UI_PREVIEW -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework AppKit -framework SwiftUI -framework IOKit -framework Carbon -framework CryptoKit -framework CoreBluetooth -framework Security -framework LocalAuthentication \
  $(rg --files macOS/Sources -g '*.swift' -g '!main.swift') macOS/Tests/FirstInstall/Preview.swift -o "$folder/Contents/MacOS/Preview"
cat > "$folder/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.keyglow.install-preview</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundleName</key><string>Keyglow Install Preview</string></dict></plist>
PLIST
mkdir -p "$folder/Contents/Resources"
cp -R macOS/Resources/. "$folder/Contents/Resources/"
codesign --force --sign - "$folder"
printf '%s\n' "$folder"
