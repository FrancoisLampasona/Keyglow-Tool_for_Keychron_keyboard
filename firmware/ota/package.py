#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline package builder/validator. Never opens a device or installs firmware."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

TARGET = 0x08613434
BASE = 0x08008000
MAX_IMAGE = 96 * 1024
MAGIC = b"KGFW0001"
HEADER = 60


def validate_image(image):
    if not 8 <= len(image) <= MAX_IMAGE:
        raise ValueError("Image must be 8..98304 bytes, linked at 0x08008000")
    stack, reset = struct.unpack_from("<II", image)
    if not (0x20000008 <= stack <= 0x20010000 and stack % 8 == 0):
        raise ValueError("Invalid STM32F401xC initial stack")
    if not (reset & 1 and BASE + 8 <= reset & ~1 < BASE + len(image)):
        raise ValueError("Reset vector is outside the relocated image")


def pack(image, build):
    validate_image(image)
    if not 0 <= build <= 0xFFFFFFFF:
        raise ValueError("Build must be an unsigned 32-bit integer")
    head = MAGIC + struct.pack("<IIII", TARGET, BASE, len(image), build)
    head += hashlib.sha256(image).digest()
    return head + struct.pack("<I", zlib.crc32(head)) + image


def unpack(package):
    if not HEADER + 8 <= len(package) <= HEADER + MAX_IMAGE:
        raise ValueError("Invalid package size")
    if package[:8] != MAGIC:
        raise ValueError("Unknown package format")
    target, address, length, build = struct.unpack_from("<IIII", package, 8)
    if target != TARGET or address != BASE or length != len(package) - HEADER:
        raise ValueError("Package target, address, or length mismatch")
    if zlib.crc32(package[:56]) != struct.unpack_from("<I", package, 56)[0]:
        raise ValueError("Package header CRC mismatch")
    image = package[HEADER:]
    if hashlib.sha256(image).digest() != package[24:56]:
        raise ValueError("Package image SHA-256 mismatch")
    validate_image(image)
    return {"format": 1, "target": target, "address": address, "length": length,
            "build": build, "sha256": package[24:56].hex()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("image", type=Path)
    create.add_argument("output", type=Path)
    create.add_argument("--build", type=int, required=True)
    check = sub.add_parser("verify")
    check.add_argument("package", type=Path)
    args = parser.parse_args()
    try:
        source = args.image if args.command == "create" else args.package
        limit = MAX_IMAGE if args.command == "create" else MAX_IMAGE + HEADER
        if source.stat().st_size > limit:
            raise ValueError("Input exceeds maximum permitted size")
        data = source.read_bytes()
        if args.command == "create":
            data = pack(data, args.build)
            with args.output.open("xb") as out:
                out.write(data)
        print(json.dumps(unpack(data), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
