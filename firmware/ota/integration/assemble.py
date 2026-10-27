#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline bootstrap phases; never programs a device or changes dist/."""
import hashlib
import hmac
import importlib.util
import json
import re
from pathlib import Path
import struct
import subprocess
import sys
import zlib
from verify import load_segments, symbols

PROJECT = Path(__file__).resolve().parents[3]
CORE = PROJECT / "firmware/ota"


def assemble(output, arm_bin):
    report = json.loads((output / "application-verification.json").read_text())
    image = (output / "application-relocated.bin").read_bytes()
    assert hashlib.sha256(image).hexdigest() == report["sha256"]
    compiler = arm_bin / "arm-none-eabi-gcc"
    qmk = PROJECT / "build/qmk-firmware"
    command = [str(compiler), "-std=c11", "-mcpu=cortex-m4", "-mthumb", "-mfloat-abi=soft", "-Os",
               "-Wall", "-Wextra", "-Werror", "-ffreestanding", "-fno-builtin", "-fno-common",
               "-ffunction-sections", "-fdata-sections", "-fno-unwind-tables", "-fno-asynchronous-unwind-tables",
               "-I" + str(CORE / "include"),
               "-I" + str(qmk / "lib/chibios/os/common/ext/ST/STM32F4xx"),
               "-I" + str(qmk / "lib/chibios/os/common/ext/ARM/CMSIS/Core/Include"),
               "-nostdlib", "-Wl,--gc-sections", "-Wl,-Map," + str(output / "loader.map"),
               "-T" + str(CORE / "stm32f401/loader.ld")]
    command += [str(CORE / p) for p in ["stm32f401/loader.c", "stm32f401/runtime.c", "src/keyglow_ota.c", "src/sha256.c", "src/keyglow_ota_auth.c"]]
    command += ["-lgcc", "-o", str(output / "loader.elf")]
    subprocess.run(command, check=True)
    symbol_text = subprocess.check_output([str(arm_bin / "arm-none-eabi-nm"), "-n", str(output / "loader.elf")], text=True)
    symbol = symbols(symbol_text)
    for name in ["busy_timeout_reset", "flash_wait", "unlock", "flush_cache", "program_flash", "erase_flash"]:
        assert 0x20000000 <= symbol[name] < 0x20010000, f"Loader busy-time function is not in RAM:{name}"
    assembly = subprocess.check_output([str(arm_bin / "arm-none-eabi-objdump"), "-d", "-j", ".data", str(output / "loader.elf")], text=True)
    (output / "loader-ram-disassembly.txt").write_text(assembly)
    assert not re.search(r"\sblx?\s+r\d+\b", assembly), "Unproven indirect RAM call"
    for match in re.finditer(r"^\s*[0-9a-f]+:.*\sblx?(?:\.w)?\s+([0-9a-f]+)\s", assembly, re.M):
        assert 0x20000000 <= int(match[1], 16) < 0x20010000, "Loader RAM code calls busy flash"
    for segment in load_segments(output / "loader.elf"):
        assert 0x08000000 <= segment["lma"] < 0x08003F00
        assert segment["lma"] + segment["size"] <= 0x08003F00
    subprocess.run([str(arm_bin / "arm-none-eabi-objcopy"), "-O", "binary", str(output / "loader.elf"), str(output / "loader-unprovisioned.bin")], check=True)
    loader = (output / "loader-unprovisioned.bin").read_bytes()
    stack, reset = struct.unpack_from("<II", loader)
    assert len(loader) <= 0x3F00 and 0x20000008 <= stack <= 0x20010000
    assert reset & 1 and 0x08000000 <= reset & ~1 < 0x08000000 + len(loader)
    # Old unsigned bootstrap outputs must not look installable after switching
    # the loader to mandatory authentication. These are this script's outputs.
    for name in ["bootstrap-phase1-staging.bin", "bootstrap-phase2-loader.bin"]:
        (output / name).unlink(missing_ok=True)
    spec = importlib.util.spec_from_file_location("ota_package", CORE / "package.py")
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    packaged = package.pack(image, report["build"])
    package.unpack(packaged)
    (output / "application-relocated.kgfw").write_bytes(packaged)
    plan = {"status": "unprovisioned-loader-not-installable", "auto_flash": False,
            "publisher_signature": None, "application_sha256": report["sha256"],
            "phases": [], "preserve_sectors": [1],
            "key_slot_address": 0x08003F00, "key_slot_bytes": 64,
            "requirements": [
                "No authenticated bootstrap exists until an explicit owner key slot, source image and AUTH_BEGIN authorization are supplied.",
                "Review exact images and obtain installation approval; no hardware operation is automated.",
                "Maintain ROM DFU until each phase is read back and independently verified.",
                "Stage the complete committed relocated image first; install loader only after verified staging.",
                "Initial sector-0 replacement is not power-cut safe; establish hardware BOOT0/SWD recovery before provisioning.",
                "After loader installation, staged application install is resumable; sector1 EEPROM is excluded.",
                "Owner HMAC and experimental LED/reserved-byte transport are bound; bulk transfer and installation need hardware qualification."]}
    (output / "bootstrap-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    print(json.dumps({"loader_bytes": len(loader), "status": plan["status"], "phases": []}, indent=2))


def authenticated_artifacts(image, loader, source, authorization, key_slot):
    """Pure offline validation/assembly; callers supply existing authorization.

    Return values include a private key-bearing loader. Never write these into a
    public build/release folder. This function neither generates nor stores keys.
    """
    if len(key_slot) != 64 or key_slot[:8] != b"KGKY0001" or key_slot[60:] != b"\xff" * 4:
        raise ValueError("Invalid owner key slot")
    key = key_slot[8:40]
    if key in (bytes(32), b"\xff" * 32) or struct.unpack_from("<I", key_slot, 56)[0] != zlib.crc32(key_slot[:56]):
        raise ValueError("Blank or corrupt owner key slot")
    key_id = hashlib.sha256(key).digest()[:16]
    if not hmac.compare_digest(key_id, key_slot[40:56]) or len(authorization) != 149:
        raise ValueError("Owner identity or authorization length mismatch")
    expected = hmac.digest(key, b"KEYGLOW-OTA-AUTH-V2" + authorization[:117], "sha256")
    if not hmac.compare_digest(expected, authorization[117:]) or authorization[116] > 1 or not hmac.compare_digest(key_id, authorization[100:116]):
        raise ValueError("Owner authorization rejected")
    target, address, length, build = struct.unpack_from("<4I", authorization)
    source_length = struct.unpack_from("<I", authorization, 48)[0]
    if target != 0x08613434 or address != 0x08008000 or length != len(image) or not 8 <= length <= 98304:
        raise ValueError("Wrong target or image bounds")
    if not hmac.compare_digest(hashlib.sha256(image).digest(), authorization[16:48]):
        raise ValueError("Target image differs from approved bytes")
    if source_length != len(source) or not 8 <= source_length <= 98304 or not hmac.compare_digest(hashlib.sha256(source).digest(), authorization[52:84]):
        raise ValueError("Source image differs from approved baseline")
    stack, reset = struct.unpack_from("<II", image)
    if not 0x20000008 <= stack <= 0x20010000 or stack & 7 or not reset & 1 or not address + 8 <= reset & ~1 < address + length:
        raise ValueError("Invalid relocated application vectors")
    if not 64 <= len(loader) <= 0x3F00:
        raise ValueError("Loader overlaps the owner key slot")
    loader_stack, loader_reset = struct.unpack_from("<II", loader)
    if not 0x20000008 <= loader_stack <= 0x20010000 or loader_stack & 7 or not loader_reset & 1 or not 0x08000000 <= loader_reset & ~1 < 0x08000000 + len(loader):
        raise ValueError("Invalid loader vectors")
    header = bytearray(b"\xff" * 256)
    header[:8] = b"KGOTA002"
    struct.pack_into("<6I", header, 8, 2, target, address, length, build, 256)
    header[32:64] = authorization[16:48]
    header[88:124] = authorization[48:84]
    header[176:208] = authorization[84:116]
    header[208:240] = authorization[117:149]
    header[240] = authorization[116]
    crc = zlib.crc32(header[:64] + header[88:124] + header[176:241])
    struct.pack_into("<IIIII", header, 64, crc, 0xA71A0A7A, 0xFFFFFFFE, 0xFFFFFFFE, 0xFFFFFFFF)
    for chunk in range((length + 255) // 256):
        header[128 + chunk // 8] &= ~(1 << (chunk % 8))
    stage = bytes(header) + image
    stage += b"\xff" * (-len(stage) % 4)
    personalized_loader = loader + b"\xff" * (0x3F00 - len(loader)) + key_slot
    return stage, personalized_loader


if __name__ == "__main__":
    assemble(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
