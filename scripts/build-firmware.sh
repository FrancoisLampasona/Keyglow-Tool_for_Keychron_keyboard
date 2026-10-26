#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
project="$PWD"
source_dir="$project/build/qmk-firmware"
arm_bin="${ARM_GCC_BIN:-$project/build/toolchains/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi/bin}"
export ARM_GCC_BIN="$arm_bin"
pin=2b493ff95f2665db719b1e95c91babb5036e72f3
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$pin" ]] || { print -u2 'Unexpected QMK source revision'; exit 1; }
export PATH="$project/build/qmk-venv/bin:$arm_bin:$PATH"
export QMK_HOME="$source_dir"
python3 "$project/firmware/apply-qmk-patch.py" "$source_dir"
keymap="$source_dir/keyboards/keychron/q6_max/iso_encoder/keymaps/tastiera_bt"
mkdir -p "$keymap" "$project/dist/firmware"
cp "$source_dir/keyboards/keychron/q6_max/iso_encoder/keymaps/keychron/keymap.c" "$keymap/keymap.c"
cat "$project/firmware/integration-hooks.example.c" >> "$keymap/keymap.c"
cp "$project/firmware/ble_rgb_protocol.c" "$project/firmware/ble_rgb_protocol.h" "$project/firmware/qmk_rgb_ble_bridge.c" "$project/firmware/qmk_rgb_ble_bridge.h" "$project/firmware/qmk_responsive_idle.c" "$project/firmware/qmk_responsive_idle.h" "$keymap/"
cat > "$keymap/rules.mk" <<'EOF'
VIA_ENABLE = yes
SRC += ble_rgb_protocol.c qmk_rgb_ble_bridge.c qmk_responsive_idle.c
EOF
cd "$source_dir"
# Build only. No DFU or flash target is invoked by this script.
make keychron/q6_max/iso_encoder:tastiera_bt -j4 SKIP_GIT=yes
cp keychron_q6_max_iso_encoder_tastiera_bt.bin "$project/dist/firmware/"
cp .build/keychron_q6_max_iso_encoder_tastiera_bt.elf "$project/dist/firmware/"
"$arm_bin/arm-none-eabi-objdump" -h .build/keychron_q6_max_iso_encoder_tastiera_bt.elf > "$project/dist/firmware/sections.txt"
cp .build/obj_keychron_q6_max_iso_encoder_tastiera_bt/src/version.h "$project/dist/firmware/build-version.h"
cd "$project"
shasum -a 256 dist/firmware/keychron_q6_max_iso_encoder_tastiera_bt.{bin,elf} > dist/firmware/SHA256SUMS
python3 scripts/verify-firmware.py
"$arm_bin/arm-none-eabi-size" dist/firmware/keychron_q6_max_iso_encoder_tastiera_bt.elf
