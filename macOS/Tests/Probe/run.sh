#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 macOS/Diagnostics/Probe/ProbeWire.swift \
  macOS/Diagnostics/Probe/ProbeRunner.swift macOS/Diagnostics/Probe/ProbeResultStore.swift \
  macOS/Diagnostics/Probe/ProbeUSBCounters.swift macOS/Sources/VIAProtocol.swift \
  macOS/Sources/VIAUSBTransport.swift macOS/Sources/RGBProtocol.swift -framework IOKit \
  macOS/Tests/Probe/ProbeTests.swift -o build/tests/hid-probe
build/tests/hid-probe
