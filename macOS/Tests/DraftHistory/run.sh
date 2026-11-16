#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 \
  macOS/Sources/DraftHistory.swift macOS/Tests/DraftHistory/DraftHistoryTests.swift \
  -o build/tests/draft-history
build/tests/draft-history
