#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
    -target arm64-apple-macos13.0 -framework AppKit -framework Combine -framework CryptoKit \
    -framework Security -framework LocalAuthentication -framework IOKit \
    macOS/Sources/FirmwareAuthorization.swift macOS/Sources/FirmwareDeltaPlan.swift \
    macOS/Sources/BluetoothOTAWire.swift macOS/Sources/BluetoothOTAChannel.swift \
    macOS/Sources/BluetoothOTAIO.swift macOS/Sources/HIDTransport.swift macOS/Sources/RGBProtocol.swift \
    macOS/Sources/Localization.swift macOS/Sources/FirmwareUpdateModel.swift macOS/Tests/FirmwareUpdate/FirmwareUpdateTests.swift \
    -o build/tests/firmware-update
build/tests/firmware-update
