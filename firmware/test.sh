#!/bin/sh
set -eu
cd "$(dirname "$0")"
output="${TMPDIR:-/tmp}/keychron-ble-rgb-test-$$"
bridge_output="${TMPDIR:-/tmp}/keychron-ble-rgb-bridge-test-$$"
trap 'rm -f "$output" "$bridge_output"' EXIT HUP INT TERM
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    ble_rgb_protocol.c test_ble_rgb_protocol.c -o "$output"
"$output"
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
    -I. -Itests/qmk_stub '-DQMK_KEYBOARD_H="qmk_mock.h"' \
    ble_rgb_protocol.c qmk_rgb_ble_bridge.c tests/test_qmk_rgb_ble_bridge.c -o "$bridge_output"
"$bridge_output"
python3 tests/test_qmk_render_transition.py
python3 tests/test_qmk_responsive_idle.py
python3 tests/test_legacy_rejection.py
python3 tests/test_lkbt51_spi_bounds.py
