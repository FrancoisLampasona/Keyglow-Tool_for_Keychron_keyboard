#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Prepare private authenticated USB bootstrap artifacts; never access hardware.

Requires an existing owner keyslot and an independently read-back full flash
dump. Does not generate device keys, use Keychain, flash, or change option bytes.
"""
import argparse
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import zlib
from assemble import authenticated_artifacts

PROJECT = Path(__file__).resolve().parents[3]
PRIVATE_ROOT = PROJECT / "build/ota-integration/private"


def private_read(path, size):
    path = path.resolve(strict=True)
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ValueError("Keyslot must be an owner-only regular file")
    content = path.read_bytes()
    if len(content) != size:
        raise ValueError("Owner keyslot must contain exactly64 bytes")
    return content


def write_private(folder, name, data):
    descriptor = os.open(folder / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def prepare(args):
    key_slot = private_read(args.key_slot, 64)
    flash = args.flash_dump.read_bytes()
    if len(flash) != 262144 or not hmac.compare_digest(hashlib.sha256(flash).hexdigest(), args.flash_sha256.lower()):
        raise ValueError("Full256KiB read-back dump or its expected SHA256 is incorrect")
    current = args.current_firmware.read_bytes()
    if not 32768 + 8 <= len(current) <= 131072:
        raise ValueError("Expected current standard-layout firmware without DFU suffix")
    # Current QMK vectors are at sector0; text at sector2. EEPROM is deliberately
    # excluded because a stock binary's padding is not the owner's settings.
    if flash[:480] != current[:480] or flash[32768:len(current)] != current[32768:]:
        raise ValueError("Read-back vectors/code do not match the selected current firmware")
    source = flash[32768:len(current)]
    spec = importlib.util.spec_from_file_location("keyglow_package", PROJECT / "firmware/ota/package.py")
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    packaged = args.package.read_bytes()
    package.unpack(packaged)
    manifest, image = packaged[8:56], packaged[60:]
    # A fresh host nonce prevents accidental session reuse. It is not a
    # monotonic anti-rollback counter; source binding supplies replay scope.
    nonce = os.urandom(16)
    prefix = manifest + struct.pack("<I", len(source)) + hashlib.sha256(source).digest() + nonce + key_slot[40:56] + b"\x00"
    authorization = prefix + hmac.digest(key_slot[8:40], b"KEYGLOW-OTA-AUTH-V2" + prefix, "sha256")
    loader = args.loader.read_bytes()
    stage, personalized_loader = authenticated_artifacts(image, loader, source, authorization, key_slot)

    output = args.output.resolve()
    private_root = PRIVATE_ROOT.resolve()
    if output == private_root or not output.is_relative_to(private_root):
        raise ValueError("Output must be a new subdirectory of build/ota-integration/private")
    private_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(private_root, 0o700)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    # No key-bearing data is written until every input check passes. No public
    # output, application bundle or existing file is ever overwritten.
    write_private(output, "bootstrap-phase1-staging.bin", stage)
    write_private(output, "bootstrap-phase2-loader-private.bin", personalized_loader)
    write_private(output, "authorization.bin", authorization)
    write_private(output, "source-image.bin", source)
    write_private(output, "target.kgfw", packaged)
    phases = [
        {"order": 1, "file": "bootstrap-phase1-staging.bin", "address": 0x08020000, "erase_sector": 5,
         "length": len(stage), "sha256": hashlib.sha256(stage).hexdigest()},
        {"order": 2, "file": "bootstrap-phase2-loader-private.bin", "address": 0x08000000, "erase_sector": 0,
         "length": len(personalized_loader), "sha256": hashlib.sha256(personalized_loader).hexdigest()},
    ]
    plan = {"status": "private-authenticated-artifacts-awaiting-exact-file-review", "auto_flash": False,
            "key_id": key_slot[40:56].hex(), "source_length": len(source), "source_sha256": hashlib.sha256(source).hexdigest(),
            "target_length": len(image), "target_sha256": hashlib.sha256(image).hexdigest(),
            "readback_flash_sha256": args.flash_sha256.lower(), "phases": phases, "preserve_sectors": [1],
            "requirements": ["The initial sector0 replacement is not power-cut safe; prove physical BOOT0/SWD recovery or explicitly resolve that risk before installation.",
                             "Remain in ROM DFU until staging and then personalized loader are read back and verified.",
                             "Do not replace old application sectors over USB before the loader validates the approved source and installs staging.",
                             "The personalized loader contains a secret; never publish, bundle or upload it."]}
    write_private(output, "bootstrap-plan.json", (json.dumps(plan, indent=2) + "\n").encode())
    print(json.dumps({"output": str(output), "status": plan["status"], "target_sha256": plan["target_sha256"]}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-slot", type=Path, required=True, help="Existing private64-byte Keyglow keyslot, not a raw key")
    parser.add_argument("--flash-dump", type=Path, required=True, help="Verified full256KiB current controller read-back")
    parser.add_argument("--flash-sha256", required=True, help="Expected SHA256 from independent read-back verification")
    parser.add_argument("--current-firmware", type=Path, required=True, help="Known current standard-layout .bin without DFU suffix")
    parser.add_argument("--package", type=Path, required=True, help="Reviewed relocated target .kgfw package")
    parser.add_argument("--loader", type=Path, required=True, help="Compiled unprovisioned loader candidate")
    parser.add_argument("--output", type=Path, required=True, help="New direct child of build/ota-integration/private")
    prepare(parser.parse_args())
