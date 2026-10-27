#!/bin/sh
# Builds only the isolated diagnostic. Never invokes a flash, loader or staging target.
set -eu
cd "$(dirname "$0")/../.."
project="$PWD"
source_dir="$project/build/qmk-firmware"
probe_dir="$source_dir/keyboards/keychron/q6_max/iso_encoder/keymaps/keyglow_probe"
baseline="$source_dir/keyboards/keychron/q6_max/iso_encoder/keymaps/tastiera_bt"
output="$project/build/bt-probe"
arm_bin="${ARM_GCC_BIN:-$project/build/toolchains/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi/bin}"
pin=2b493ff95f2665db719b1e95c91babb5036e72f3
[ "$(git -C "$source_dir" rev-parse HEAD)" = "$pin" ] || { echo 'Unexpected QMK source revision' >&2; exit 1; }
mkdir -p "$probe_dir" "$output/qmk-output"
for name in ble_rgb_protocol qmk_rgb_ble_bridge qmk_responsive_idle; do
    for suffix in c h; do
        cmp "$project/firmware/$name.$suffix" "$baseline/$name.$suffix"
        cp "$baseline/$name.$suffix" "$probe_dir/"
    done
done
cp "$project/firmware/diagnostics/"*.[ch] "$probe_dir/"
python3 - "$baseline/keymap.c" "$probe_dir/keymap.c" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
needle = '    if (!rgb_ble_bridge_led_update(led_state)) return false;'
assert text.count(needle) == 1
text = text.replace('#include "qmk_rgb_ble_bridge.h"', '#include "qmk_rgb_ble_bridge.h"\n#include "qmk_reserved_probe.h"')
text = text.replace(needle, '    keyglow_probe_led_update(led_state);\n' + needle)
text += '''
bool pre_process_record_user(uint16_t keycode, keyrecord_t *record) {
    (void)keycode;
    keyglow_probe_key_event(record);
    return true;
}
void housekeeping_task_user(void) { keyglow_probe_task(); }
'''
pathlib.Path(sys.argv[2]).write_text(text)
PY
cat > "$probe_dir/rules.mk" <<'EOF'
VIA_ENABLE = yes
SRC += ble_rgb_protocol.c qmk_rgb_ble_bridge.c qmk_responsive_idle.c reserved_probe.c qmk_reserved_probe.c
EOF
export PATH="$project/build/qmk-venv/bin:$arm_bin:$PATH"
export QMK_HOME="$source_dir"
cd "$source_dir"
# ELF target prevents QMK copying a bin into the shared checkout root.
make keychron/q6_max/iso_encoder:keyglow_probe:elf -j4 SKIP_GIT=yes BUILD_DIR="$output/qmk-output" > "$output/build.log" 2>&1
target=keychron_q6_max_iso_encoder_keyglow_probe
cp "$output/qmk-output/$target.elf" "$output/$target.elf"
"$arm_bin/arm-none-eabi-objcopy" -O binary "$output/$target.elf" "$output/$target.bin"
"$arm_bin/arm-none-eabi-objdump" -h "$output/$target.elf" > "$output/sections.txt"
"$arm_bin/arm-none-eabi-size" "$output/$target.elf" > "$output/size.txt"
cd "$output"
shasum -a 256 "$target.bin" "$target.elf" > SHA256SUMS
cat size.txt SHA256SUMS
