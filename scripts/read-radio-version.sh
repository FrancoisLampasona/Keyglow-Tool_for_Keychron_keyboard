#!/bin/sh
# --read sends only the version query 0x60. --self-test never opens hardware.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_BUILD_DIR="$TASK_ROOT/build/diagnostics/radio-version"
case "${1:---help}" in
    --read|--self-test|--build-only|--help) ;;
    *) printf '%s\n' 'Argomento non valido. Usa --help.' >&2; exit 64 ;;
esac
if [ "$#" -gt 1 ]; then
    printf '%s\n' 'È consentito un solo argomento.' >&2
    exit 64
fi
mkdir -p "$TASK_BUILD_DIR/module-cache"
# Swift rejects two source files with the same basename in one module.
cp "$TASK_ROOT/macOS/Diagnostics/RadioVersion.swift" "$TASK_BUILD_DIR/RadioVersionCLI.swift"
/usr/bin/xcrun swiftc -swift-version 6 -parse-as-library -O \
    -module-cache-path "$TASK_BUILD_DIR/module-cache" \
    "$TASK_ROOT/macOS/Sources/RadioVersion.swift" \
    "$TASK_BUILD_DIR/RadioVersionCLI.swift" \
    -framework IOKit -o "$TASK_BUILD_DIR/read-radio-version"
if [ "${1:---help}" = '--build-only' ]; then
    printf '%s\n' "$TASK_BUILD_DIR/read-radio-version"
    exit 0
fi
exec "$TASK_BUILD_DIR/read-radio-version" "${1:---help}"
