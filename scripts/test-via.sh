#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache
xcrun swiftc -swift-version 6 -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework IOKit \
  macOS/Sources/VIAProtocol.swift macOS/Sources/VIAUSBTransport.swift macOS/Sources/VIAClient.swift macOS/Tests/VIA/main.swift \
  -o build/test-via
build/test-via
