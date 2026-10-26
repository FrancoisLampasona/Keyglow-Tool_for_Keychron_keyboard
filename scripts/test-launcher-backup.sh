#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/tastiera-launcher-backup.XXXXXX")"
trap 'rm -rf "$output_dir"' EXIT
node macOS/Tests/LauncherBackup/fixtures.cjs "$output_dir"
xcrun swiftc -swift-version 6 -module-cache-path "$output_dir/swift-cache" \
  -target arm64-apple-macos13.0 \
  macOS/Sources/KeyboardDefinition.swift macOS/Sources/LauncherBackup.swift \
  macOS/Tests/LauncherBackup/main.swift -o "$output_dir/test-launcher-backup"
"$output_dir/test-launcher-backup" "$output_dir"
node macOS/Tests/LauncherBackup/verify.cjs "$output_dir"
