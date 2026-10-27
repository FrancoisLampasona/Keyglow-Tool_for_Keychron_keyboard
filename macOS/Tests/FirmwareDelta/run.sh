#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 \
    -framework Foundation -framework CryptoKit \
    macOS/Sources/FirmwareDeltaPlan.swift \
    macOS/Tests/FirmwareDelta/FirmwareDeltaTests.swift \
    -o build/tests/firmware-delta
build/tests/firmware-delta
