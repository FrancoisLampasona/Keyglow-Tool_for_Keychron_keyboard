#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/.."
QMK_ROOT=${QMK_ROOT:-../../build/qmk-firmware}
ARM_TOOLCHAIN=${ARM_TOOLCHAIN:-../../build/toolchains/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi/bin/arm-none-eabi-}
mkdir -p build
"${ARM_TOOLCHAIN}gcc" -std=c11 -mcpu=cortex-m4 -mthumb -mfloat-abi=soft \
    -Os -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-common \
    -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -Iinclude \
    -I"$QMK_ROOT/lib/chibios/os/common/ext/ST/STM32F4xx" \
    -I"$QMK_ROOT/lib/chibios/os/common/ext/ARM/CMSIS/Core/Include" \
    -nostdlib -Wl,--gc-sections -Wl,-Map,build/keyglow-loader.map \
    -Tstm32f401/loader.ld stm32f401/loader.c stm32f401/runtime.c src/keyglow_ota.c src/sha256.c src/keyglow_ota_auth.c \
    -lgcc -o build/keyglow-loader.elf
"${ARM_TOOLCHAIN}size" build/keyglow-loader.elf
# Deliberately no .bin export, hardware programming or device commands.
