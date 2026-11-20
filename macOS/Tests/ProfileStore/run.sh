#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 \
  macOS/Sources/KeyboardDefinition.swift macOS/Sources/KeyGroups.swift macOS/Sources/WorkspaceDocument.swift \
  macOS/Sources/ProfileStore.swift macOS/Tests/ProfileStore/ProfileStoreTests.swift \
  -o build/tests/profile-store
build/tests/profile-store
