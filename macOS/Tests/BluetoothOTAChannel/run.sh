#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
 macOS/Sources/BluetoothOTAWire.swift macOS/Sources/BluetoothOTAChannel.swift \
 macOS/Tests/BluetoothOTAChannel/ChannelTests.swift -o build/tests/ota-channel
build/tests/ota-channel
