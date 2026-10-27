#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
clang -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
 -Ifirmware/ota/include -Ifirmware/ota/src -Ifirmware/ota/ble \
 firmware/ota/src/keyglow_ota.c firmware/ota/src/keyglow_ota_auth.c firmware/ota/src/keyglow_ota_wire.c firmware/ota/src/sha256.c \
 firmware/ota/ble/keyglow_ble_wire.c macOS/Tests/FirmwareEngine/EngineBridge.c -o build/tests/firmware-core-bridge
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
 -target arm64-apple-macos13.0 -framework AppKit -framework Combine -framework CryptoKit \
 -framework Security -framework LocalAuthentication -framework IOKit \
 macOS/Sources/FirmwareAuthorization.swift macOS/Sources/FirmwareDeltaPlan.swift \
 macOS/Sources/BluetoothOTAWire.swift macOS/Sources/BluetoothOTAChannel.swift \
 macOS/Sources/BluetoothOTAIO.swift macOS/Sources/HIDTransport.swift macOS/Sources/RGBProtocol.swift \
 macOS/Sources/FirmwareUpdateModel.swift macOS/Tests/FirmwareEngine/EngineTests.swift -o build/tests/firmware-core-host
build/tests/firmware-core-host "$PWD/build/tests/firmware-core-bridge" \
 "$PWD/build/ota-integration/variant-a/application-relocated.bin" \
 "$PWD/build/ota-integration/variant-b/application-relocated.kgfw"
