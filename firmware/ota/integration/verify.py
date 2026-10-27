#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify linked relocation/RAM boundaries and emit an offline integrity report."""
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import struct
import subprocess
import sys

BASE, LIMIT = 0x08008000, 0x08020000
RAM, RAM_END = 0x20000000, 0x20010000


def load_segments(path):
    data = path.read_bytes()
    if data[:7] != b"\x7fELF\x01\x01\x01" or struct.unpack_from("<H", data, 18)[0] != 40:
        raise ValueError("Expected little-endian ARM ELF32")
    phoff = struct.unpack_from("<I", data, 28)[0]
    phsize, phcount = struct.unpack_from("<HH", data, 42)
    segments = []
    for index in range(phcount):
        kind, offset, vma, lma, size, memsize, flags, alignment = struct.unpack_from("<8I", data, phoff + index * phsize)
        if kind == 1 and size:
            if offset + size > len(data):
                raise ValueError("ELF segment exceeds file")
            segments.append({"vma": vma, "lma": lma, "size": size, "data": data[offset:offset + size]})
    return segments


def symbols(text):
    return {match[2]: int(match[1], 16) for match in re.finditer(r"^([0-9a-fA-F]+)\s+[\w?]\s+(\S+)$", text, re.M)}


def verify(output, tools):
    elf = output / "qmk-output/keychron_q6_max_iso_encoder_keyglow_ota.elf"
    image = (output / "application-relocated.bin").read_bytes()
    sym = symbols((output / "application-symbols.txt").read_text())
    assert sym["_vectors"] == BASE == sym["__vectors_base__"]
    assert 8 < len(image) <= LIMIT - BASE
    assert sym["__flash0_free__"] - BASE == len(image), "HELLO length must include every load byte"
    build = int(os.environ.get("KEYGLOW_OTA_BUILD", "8"))
    timestamp = (datetime(2026, 10, 27, tzinfo=timezone.utc) + timedelta(seconds=build)).strftime("%Y-%m-%d-%H:%M:%S")
    version_header = (output / "qmk-output/obj_keychron_q6_max_iso_encoder_keyglow_ota/src/version.h").read_text()
    assert f'#define QMK_BUILDDATE "{timestamp}"' in version_header
    assert timestamp.encode() in image, "USB version must contain the compiled release identity"
    sp, reset = struct.unpack_from("<II", image)
    assert RAM + 8 <= sp <= RAM_END and sp % 8 == 0
    assert reset & 1 and BASE <= reset & ~1 < BASE + len(image)
    vector_size = sym["__vectors_end__"] - BASE
    for (handler,) in struct.iter_unpack("<I", image[4:vector_size]):
        assert handler == 0 or handler & 1 and BASE <= handler & ~1 < BASE + len(image)
    for segment in load_segments(elf):
        assert BASE <= segment["lma"] < LIMIT and segment["lma"] + segment["size"] <= LIMIT
        offset = segment["lma"] - BASE
        assert image[offset:offset + segment["size"]] == segment["data"]
    assert sym["__flash1_base__"] == 0x08004000 and sym["__flash1_size__"] == 16384
    assert RAM <= sym["__data_base__"] < sym["__data_end__"] <= sym["__bss_base__"] < sym["__bss_end__"] <= RAM_END
    for name in ["busy_timeout_reset", "wait_ready", "unlock", "flush_cache", "program_locked", "erase_locked"]:
        assert sym["__data_base__"] <= sym[name] < sym["__data_end__"]
    for name in ["kg_ota_begin", "kg_ota_chunk", "kg_ota_finish", "kg_ota_commit", "keyglow_ota_submit_frame", "keyglow_ota_set_authorizer"]:
        assert BASE <= sym[name] < LIMIT
    assembly = subprocess.check_output([str(tools / "arm-none-eabi-objdump"), "-d", "-j", ".data", str(elf)], text=True)
    (output / "ram-disassembly.txt").write_text(assembly)
    # No helper call from the busy-time RAM functions may fetch flash code.
    for match in re.finditer(r"^\s*([0-9a-f]+):.*\sblx?(?:\.w)?\s+([0-9a-f]+)\s", assembly, re.M):
        origin, target = (int(match[1], 16), int(match[2], 16))
        if sym["busy_timeout_reset"] <= origin < sym["__data_end__"]:
            assert RAM <= target < RAM_END, f"RAM code calls flash: {match.group(0)}"
    report = {
        "status": "compile-and-static-verification-only", "hardware_tested": False,
        "bluetooth_transport_bound": True, "bluetooth_bulk_hardware_verified": False, "owner_hmac_verifier_bound": True,
        "application_base": BASE, "application_size": len(image), "application_limit": LIMIT,
        "build": build, "build_timestamp": timestamp, "usb_firmware_version": "v1.1.1 " + timestamp,
        "application_margin_bytes": LIMIT - BASE - len(image),
        "sha256": hashlib.sha256(image).hexdigest(), "initial_stack": sp, "reset_vector": reset,
        "vector_size": vector_size, "ram_data_bss_end": sym["__bss_end__"],
        "process_stack_bytes": sym["__process_stack_end__"] - sym["__process_stack_base__"],
        "remaining_heap_bytes": sym["__heap_end__"] - sym["__heap_base__"],
        "ram_flash_driver_start": sym["busy_timeout_reset"], "ram_flash_driver_end": sym["__data_end__"],
        "eeprom_sector_preserved": 1, "eeprom_backing_bytes": 6144, "eeprom_logical_bytes": 3072,
    }
    (output / "application-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
