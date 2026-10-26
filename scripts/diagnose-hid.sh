#!/bin/sh
# Read-only hardware discovery by default; --read-led is an explicit opt-in.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_BUILD_DIR="${TMPDIR:-/tmp}/tastiera-hid-diagnostics"
mkdir -p "$TASK_BUILD_DIR/module-cache"
/usr/bin/xcrun swiftc -swift-version 6 \
    -module-cache-path "$TASK_BUILD_DIR/module-cache" \
    "$TASK_ROOT/macOS/Sources/RGBProtocol.swift" \
    "$TASK_ROOT/macOS/Sources/HIDTransport.swift" \
    "$TASK_ROOT/macOS/Diagnostics/main.swift" \
    -framework IOKit \
    -o "$TASK_BUILD_DIR/diagnose-hid"
exec "$TASK_BUILD_DIR/diagnose-hid" "$@"
