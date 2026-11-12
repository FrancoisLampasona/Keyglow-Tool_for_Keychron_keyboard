#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/tests build/swift-cache
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/build/swift-cache" \
  -target arm64-apple-macos13.0 -framework AppKit -framework IOKit \
  macOS/Sources/OnboardingModel.swift macOS/Sources/KeyboardSetup.swift \
  macOS/Sources/VIAProtocol.swift macOS/Sources/VIAUSBTransport.swift macOS/Sources/VIAClient.swift macOS/Sources/EnergyPolicy.swift \
  macOS/Tests/Onboarding/OnboardingTests.swift \
  -o build/tests/onboarding
build/tests/onboarding
