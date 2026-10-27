#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
project=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)
qmk="$project/build/qmk-firmware"
output=${KEYGLOW_OTA_OUTPUT:-$project/build/ota-integration}
arm_bin=${ARM_GCC_BIN:-$project/build/toolchains/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi/bin}
export PATH="$project/build/qmk-venv/bin:$arm_bin:$PATH"
export QMK_HOME="$qmk"
python3 "$project/firmware/ota/integration/prepare.py"
mkdir -p "$output/qmk-output"
cd "$qmk"
# ELF-only avoids QMK's copy-to-repository-root and DFU suffix rules.
# QMK's timestamp generator ignores SOURCE_DATE_EPOCH. A narrow wrapper emits
# deterministic, distinct Keyglow A/B identities without editing shared QMK code.
make keychron/q6_max/iso_encoder:keyglow_ota:elf -j4 SKIP_GIT=yes SKIP_VERSION=yes \
    QMK_BIN="$project/firmware/ota/integration/qmk-command.py" \
    BUILD_DIR="$output/qmk-output" \
    EXTRAFLAGS=-fstack-usage \
    LDSCRIPT="$qmk/keyboards/keychron/q6_max/iso_encoder/keymaps/keyglow_ota/qmk_app.ld"
target="$output/qmk-output/keychron_q6_max_iso_encoder_keyglow_ota.elf"
"$arm_bin/arm-none-eabi-size" "$target"
"$arm_bin/arm-none-eabi-objdump" -h "$target" > "$output/application-sections.txt"
"$arm_bin/arm-none-eabi-nm" -n "$target" > "$output/application-symbols.txt"
# Application-only bytes have no sector-0/EEPROM hole or DFU suffix.
"$arm_bin/arm-none-eabi-objcopy" -O binary "$target" "$output/application-relocated.bin"
python3 "$project/firmware/ota/integration/verify.py" "$output" "$arm_bin"
python3 "$project/firmware/ota/integration/assemble.py" "$output" "$arm_bin"
