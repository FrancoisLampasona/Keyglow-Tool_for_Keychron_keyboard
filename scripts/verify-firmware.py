#!/usr/bin/env python3
"""Validate the prepared Q6 Max ISO binary and write its manifest. No hardware I/O."""
from pathlib import Path
import hashlib
import os
import json
import re
import struct
import subprocess
import zlib

root = Path(__file__).resolve().parent.parent
source = root / 'build/qmk-firmware'
pin = '2b493ff95f2665db719b1e95c91babb5036e72f3'
assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == pin
folder = root / 'dist/firmware'
binary = folder / 'keychron_q6_max_iso_encoder_tastiera_bt.bin'
data = binary.read_bytes()
assert data[-8:-5] == b'UFD' and data[-5] == 16, 'Missing DFU suffix'
assert (zlib.crc32(data[:-4]) ^ 0xffffffff) == struct.unpack('<I', data[-4:])[0], 'DFU checksum mismatch'
stack, reset = struct.unpack('<II', data[:8])
assert 0x20000000 < stack <= 0x20010000 and reset & 1 and 0x08008000 <= reset < 0x08040000
assert len(data) - 16 <= 262144, 'Image exceeds target flash'
descriptors = [i for i in range(len(data) - 18) if data[i:i+2] == b'\x12\x01' and data[i+8:i+12] == bytes.fromhex('34346108')]
assert len(descriptors) == 1 and data[descriptors[0]+12:descriptors[0]+14] == bytes.fromhex('1101'), 'Unexpected USB identity'
assert data[0x4000:0x8000] == bytes(16384), 'Unexpected EEPROM filler'
names = ['ble_rgb_protocol.c', 'ble_rgb_protocol.h', 'qmk_rgb_ble_bridge.c', 'qmk_rgb_ble_bridge.h', 'qmk_responsive_idle.c', 'qmk_responsive_idle.h', 'integration-hooks.example.c', 'apply-qmk-patch.py']
for name in names[:6]:
    assert (root / 'firmware' / name).read_bytes() == (source / 'keyboards/keychron/q6_max/iso_encoder/keymaps/tastiera_bt' / name).read_bytes(), 'Source copy differs'
arm_bin = Path(os.environ.get('ARM_GCC_BIN', str(root / 'build/toolchains/arm-gnu-toolchain-13.3.rel1-darwin-arm64-arm-none-eabi/bin')))
nm = arm_bin / 'arm-none-eabi-nm'
symbols = subprocess.check_output([str(nm), str(folder / 'keychron_q6_max_iso_encoder_tastiera_bt.elf')], text=True)
for name in ['rgb_matrix_set_config_noeeprom', 'rgb_matrix_save_lighting', 'rgb_save_retail_demo_if_changed', 'ble_rgb_receiving', 'q6_responsive_idle_active', 'lpm_is_kb_idle', 'q6_lpm_is_idle_user', 'battery_has_valid_reading', 'wireless_get_connected_idle_timeout']:
    assert re.search(r' T ' + name + r'$', symbols, re.M), f'Missing strong firmware symbol: {name}'
manifest = {
    'capabilities': ['rgb-ble-v2', 'rgb-ble-v3-direct', 'rgb-ble-persistent', 'atomic-rgb-transition', 'reactive-idle-65520'],
    'target': 'keychron/q6_max/iso_encoder:tastiera_bt', 'sourceCommit': pin,
    'binary': binary.name, 'bytesIncludingDFUSuffix': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
    'initialStackPointer': hex(stack), 'resetVector': hex(reset), 'USB': '3434:0861', 'bcdDevice': '1.1.1',
    'dfuSuffixCRCValid': True, 'eepromRegionWillBeOverwritten': True,
    'buildTimestamp': re.search(r'QMK_BUILDDATE "([^"]+)"', (folder / 'build-version.h').read_text())[1],
    'toolchain': subprocess.check_output([str(arm_bin / 'arm-none-eabi-gcc'), '--version'], text=True).splitlines()[0],
    'sourceFilesSHA256': {name: hashlib.sha256((root / 'firmware' / name).read_bytes()).hexdigest() for name in names},
    'status': 'Compiled and statically validated. This check does not flash or prove Bluetooth delivery.'
}
(folder / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Validated Q6 Max ISO binary: {len(data)} bytes; SHA256 {manifest["sha256"]}')
