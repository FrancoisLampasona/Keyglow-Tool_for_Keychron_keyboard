#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache build/tests
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 -framework AppKit -framework SwiftUI -framework Carbon macOS/Sources/QuickLaunch.swift macOS/Tests/QuickLaunch/QuickLaunchTests.swift -o build/tests/quick-launch
build/tests/quick-launch
