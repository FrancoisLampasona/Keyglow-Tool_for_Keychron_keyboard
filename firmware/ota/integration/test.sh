#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
project=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)
integration="$project/firmware/ota/integration"
core="$project/firmware/ota"
output=${KEYGLOW_OTA_OUTPUT:-$project/build/ota-integration}
mkdir -p "$output"
cc -std=c11 -Wall -Wextra -Werror -pedantic -O1 -g \
   -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
   -I"$integration/tests/stubs" -I"$integration" -I"$core/include" \
   "$integration/qmk_ota_adapter.c" "$core/src/keyglow_ota.c" \
   "$core/src/keyglow_ota_wire.c" "$core/src/keyglow_ota_auth.c" "$core/src/sha256.c" \
   "$integration/tests/test_adapter.c" -o "$output/test_adapter"
"$output/test_adapter"
if [ -f "$output/application-relocated.bin" ] && [ -f "$output/loader-unprovisioned.bin" ]; then
    python3 -B "$integration/tests/assemble_fixture.py" "$output"
    cc -std=c11 -Wall -Wextra -Werror -pedantic -O1 -g \
       -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
       -I"$core/include" "$core/src/keyglow_ota.c" "$core/src/sha256.c" "$core/src/keyglow_ota_auth.c" \
       "$integration/tests/test_bootstrap.c" -o "$output/test_bootstrap"
    "$output/test_bootstrap" \
       "$output/application-relocated.bin" \
       "$output/test-bootstrap-stage.bin"
fi
