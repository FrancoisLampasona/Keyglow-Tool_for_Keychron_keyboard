#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/swift-cache" \
  macOS/Sources/RGBProtocol.swift macOS/Tests/main.swift -o build/protocol-tests
build/protocol-tests
