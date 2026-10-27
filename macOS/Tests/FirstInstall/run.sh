#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
fixture="$(mktemp -d "$PWD/build/tests/first-install.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework AppKit -framework Combine -framework CryptoKit -framework Security -framework LocalAuthentication -framework IOKit \
  macOS/Sources/FirmwareAuthorization.swift macOS/Sources/FirmwareDeltaPlan.swift \
  macOS/Sources/BluetoothOTAWire.swift macOS/Sources/BluetoothOTAChannel.swift macOS/Sources/BluetoothOTAIO.swift \
  macOS/Sources/HIDTransport.swift macOS/Sources/RGBProtocol.swift macOS/Sources/Localization.swift macOS/Sources/FirmwareUpdateModel.swift \
  macOS/Sources/VIAProtocol.swift macOS/Sources/FirstInstallCore.swift macOS/Tests/FirstInstall/FirstInstallTests.swift \
  -o build/tests/first-install
build/tests/first-install "$fixture"
python3 - "$fixture" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0,'firmware/ota/integration')
from assemble import authenticated_artifacts
root=Path(sys.argv[1])
args=[(root/name).read_bytes() for name in ['fixture-image.bin','fixture-loader.bin','fixture-source.bin','fixture-auth.bin','fixture-keyslot.bin']]
stage,loader=authenticated_artifacts(*args)
assert stage == (root/'swift-stage.bin').read_bytes()
assert loader == (root/'swift-loader.bin').read_bytes()
print('Swift bootstrap bytes match the independently implemented Python assembler.')
PY
