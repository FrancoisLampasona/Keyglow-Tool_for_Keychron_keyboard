#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache
xcrun swiftc -swift-version 6 -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 \
  macOS/Sources/EnergyPolicy.swift macOS/Sources/KeyboardDefinition.swift macOS/Sources/WorkspaceDocument.swift macOS/Tests/Energy/main.swift -o build/test-energy
build/test-energy
