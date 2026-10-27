#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build/bt-probe/tests
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
  -Ifirmware/diagnostics firmware/diagnostics/reserved_probe.c \
  firmware/diagnostics/tests/test_reserved_probe.c -o build/bt-probe/tests/reserved-probe
build/bt-probe/tests/reserved-probe
cc -std=c11 -Wall -Wextra -Werror -pedantic -fsanitize=address,undefined \
  -Ifirmware/diagnostics/tests/qmk_stub -Ifirmware/diagnostics -Ifirmware \
  '-DQMK_KEYBOARD_H="qmk_probe_mock.h"' firmware/diagnostics/reserved_probe.c \
  firmware/diagnostics/qmk_reserved_probe.c firmware/diagnostics/tests/test_qmk_reserved_probe.c \
  -o build/bt-probe/tests/qmk-reserved-probe
build/bt-probe/tests/qmk-reserved-probe
