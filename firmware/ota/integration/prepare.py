#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Prepare only the isolated keyglow_ota keymap; never patch shared QMK sources."""
from pathlib import Path
import shutil
import subprocess
import os

PROJECT = Path(__file__).resolve().parents[3]
QMK = PROJECT / "build/qmk-firmware"
PIN = "2b493ff95f2665db719b1e95c91babb5036e72f3"
actual = subprocess.check_output(["git", "-C", str(QMK), "rev-parse", "HEAD"], text=True).strip()
if actual != PIN:
    raise SystemExit("Unexpected QMK revision")
check = subprocess.check_output(["python3", str(PROJECT / "firmware/apply-qmk-patch.py"), str(QMK), "--check"], text=True)
if "Would patch:" in check:
    raise SystemExit("Shared QMK v0.6 hooks are missing; this script will not patch them")
keymap = QMK / "keyboards/keychron/q6_max/iso_encoder/keymaps/keyglow_ota"
keymap.mkdir(parents=True, exist_ok=True)
for name in ["ble_rgb_protocol.c", "ble_rgb_protocol.h", "qmk_rgb_ble_bridge.c", "qmk_rgb_ble_bridge.h", "qmk_responsive_idle.c", "qmk_responsive_idle.h"]:
    shutil.copy2(PROJECT / "firmware" / name, keymap / name)
for directory in ["src", "include"]:
    for source in (PROJECT / "firmware/ota" / directory).glob("*.[ch]"):
        shutil.copy2(source, keymap / source.name)
for source in Path(__file__).parent.glob("qmk_ota_*.[ch]"):
    shutil.copy2(source, keymap / source.name)
for name in ["keyglow_ble_wire.c", "keyglow_ble_wire.h", "qmk_ble_ota.c", "qmk_ble_ota.h"]:
    shutil.copy2(PROJECT / "firmware/ota/ble" / name, keymap / name)
shutil.copy2(PROJECT / "firmware/ota/stm32f401/qmk_app.ld", keymap / "qmk_app.ld")
keymap_source = (keymap.parent / "keychron/keymap.c").read_text()
hooks = (PROJECT / "firmware/integration-hooks.example.c").read_text()
hooks = '#include "qmk_ota_adapter.h"\n#include "qmk_ble_ota.h"\n' + hooks
hooks = hooks.replace('if (!rgb_ble_bridge_process_record', 'keyglow_ble_ota_process_record(record);\n    keyglow_ota_note_key();\n    if (!rgb_ble_bridge_process_record')
hooks = hooks.replace('if (!rgb_ble_bridge_led_update', 'if (!keyglow_ble_ota_led_update(led_state)) return false;\n    if (!rgb_ble_bridge_led_update')
hooks = hooks.replace('rgb_ble_bridge_matrix_scan();', 'keyglow_ble_ota_task();\n    keyglow_ota_task();\n    rgb_ble_bridge_matrix_scan();')
(keymap / "keymap.c").write_text(keymap_source + "\n" + hooks)
idle = (keymap / "qmk_responsive_idle.c").read_text()
idle = '#include "qmk_ota_adapter.h"\n#include "qmk_ble_ota.h"\n' + idle
idle = idle.replace('return !q6_responsive_idle_active();', 'return !q6_responsive_idle_active() && !keyglow_ota_busy() && !keyglow_ble_ota_busy();')
(keymap / "qmk_responsive_idle.c").write_text(idle)
build = int(os.environ.get("KEYGLOW_OTA_BUILD", "8"))
if not 0 <= build <= 0xFFFFFFFF:
    raise SystemExit("KEYGLOW_OTA_BUILD must be a u32")
(keymap / "rules.mk").write_text('''# Isolated relocated application; experimental LED/reserved-byte OTA adapter.
VIA_ENABLE = yes
# Leave stack headroom for nested receiver/SHA verification in the matrix task.
USE_PROCESS_STACKSIZE = 0x1000
SRC += ble_rgb_protocol.c qmk_rgb_ble_bridge.c qmk_responsive_idle.c
SRC += keyglow_ota.c keyglow_ota_wire.c keyglow_ota_auth.c sha256.c qmk_ota_flash.c qmk_ota_adapter.c
SRC += keyglow_ble_wire.c qmk_ble_ota.c
# Retain the explicit future transport/policy interface in the linked image.
LDFLAGS += -Wl,--undefined=keyglow_ota_submit_frame
LDFLAGS += -Wl,--undefined=keyglow_ota_peek_reply
LDFLAGS += -Wl,--undefined=keyglow_ota_reply_delivered
LDFLAGS += -Wl,--undefined=keyglow_ota_set_authorizer
''' + f"OPT_DEFS += -DKEYGLOW_OTA_BUILD={build}\n")
print(keymap.relative_to(PROJECT))
