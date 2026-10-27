#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 macOS/Sources/BluetoothOTAWire.swift \
  macOS/Sources/RGBProtocol.swift macOS/Tests/BluetoothOTA/WireTests.swift \
  -o build/tests/bluetooth-ota-wire
build/tests/bluetooth-ota-wire firmware/ota/ble/vectors.json
