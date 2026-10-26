#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output_dir="$(mktemp -d "${TMPDIR:-/tmp}/tastiera-launcher-macros.XXXXXX")"
trap 'rm -rf "$output_dir"' EXIT
node macOS/Tests/LauncherMacros/fixtures.cjs "$output_dir"
xcrun swiftc -swift-version 6 -module-cache-path "$output_dir/swift-cache" \
  -target arm64-apple-macos13.0 \
  macOS/Sources/KeyboardDefinition.swift macOS/Sources/WorkspaceDocument.swift \
  macOS/Sources/LauncherMacroBackup.swift macOS/Tests/LauncherMacros/main.swift \
  -o "$output_dir/test-launcher-macros"
"$output_dir/test-launcher-macros" "$output_dir"
node macOS/Tests/LauncherMacros/verify.cjs "$output_dir"
