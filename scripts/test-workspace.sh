#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/swift-cache
xcrun swiftc -swift-version 6 -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 \
  macOS/Sources/KeyboardDefinition.swift macOS/Sources/WorkspaceDocument.swift macOS/Tests/Workspace/main.swift \
  -o build/test-workspace
build/test-workspace
