#!/bin/zsh
# Fetch the pinned QMK source; never flash or reset an existing checkout.
set -euo pipefail
cd "${0:A:h:h}"
source_dir="$PWD/build/qmk-firmware"
pin=2b493ff95f2665db719b1e95c91babb5036e72f3
if [[ ! -d "$source_dir" ]]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init
  git -C "$source_dir" remote add origin https://github.com/Keychron/qmk_firmware.git
  git -C "$source_dir" fetch --depth=1 origin "$pin"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$pin" ]] || { print -u2 'Unexpected QMK revision; existing checkout left unchanged.'; exit 1; }
if [[ "${1:-}" == --source-only ]]; then exit 0; fi
git -C "$source_dir" submodule update --init --depth=1 lib/chibios lib/chibios-contrib lib/printf
python3 -m venv build/qmk-venv
build/qmk-venv/bin/python -m pip install -r firmware/requirements.txt
printf '%s\n' 'Source and Python environment ready. Provide Arm GNU 13.3.Rel1 using ARM_GCC_BIN before scripts/build-firmware.sh.'
