#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
bundle="$PWD/build/Keyglow Bluetooth Diagnostics.app"
mkdir -p "$bundle/Contents/MacOS" "$PWD/build/swift-cache" "$PWD/research/bluetooth-v08"
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/build/swift-cache" -target arm64-apple-macos13.0 \
  -framework AppKit -framework CoreBluetooth macOS/Diagnostics/Bluetooth/GATTDiscovery.swift -o "$bundle/Contents/MacOS/KeyglowBTDiagnostics"
python3 - "$bundle" "$PWD/research/bluetooth-v08/gatt-inventory.json" <<'PY'
import plistlib,sys
from pathlib import Path
p={'CFBundleIdentifier':'local.keyglow.bluetooth-diagnostics','CFBundleName':'Keyglow Bluetooth Diagnostics','CFBundleExecutable':'KeyglowBTDiagnostics','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'13.0','NSBluetoothAlwaysUsageDescription':'Keyglow legge i servizi della tua Q6 Max per verificare il canale per futuri aggiornamenti. Non scrive firmware né registra digitazione.','KeyglowDiagnosticOutput':sys.argv[2]}
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps(p))
PY
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s\n' "$bundle"
