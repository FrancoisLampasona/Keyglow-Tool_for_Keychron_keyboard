#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 \
    -framework Foundation -framework CryptoKit -framework Security -framework LocalAuthentication \
    macOS/Sources/FirmwareAuthorization.swift \
    macOS/Tests/FirmwareAuthorization/FirmwareAuthorizationTests.swift \
    -o build/tests/firmware-authorization
build/tests/firmware-authorization
