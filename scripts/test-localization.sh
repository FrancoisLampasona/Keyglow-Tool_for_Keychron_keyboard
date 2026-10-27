#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache
xcrun swiftc -swift-version 6 -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 \
 macOS/Sources/Localization.swift macOS/Tests/Localization/LocalizationTests.swift -o build/test-localization
build/test-localization macOS/Resources/Localization.json
