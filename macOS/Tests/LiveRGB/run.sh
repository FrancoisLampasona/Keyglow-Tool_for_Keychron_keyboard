#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 macOS/Sources/RGBProtocol.swift macOS/Sources/LiveRGB.swift \
  macOS/Tests/LiveRGB/LiveRGBTests.swift -o build/tests/live-rgb
build/tests/live-rgb
