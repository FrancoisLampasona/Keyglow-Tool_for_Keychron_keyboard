#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Public deterministic test key; never a provisioning or production artifact."""
import hashlib
import hmac
from pathlib import Path
import struct
import sys
import zlib
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from assemble import authenticated_artifacts

output = Path(sys.argv[1])
image = (output / "application-relocated.bin").read_bytes()
loader = (output / "loader-unprovisioned.bin").read_bytes()
source = bytes([0x5A]) * 1024  # Intentionally has no valid application vectors.
key = bytes(range(1, 33))
key_id = hashlib.sha256(key).digest()[:16]
slot_prefix = b"KGKY0001" + key + key_id
slot = slot_prefix + struct.pack("<I", zlib.crc32(slot_prefix)) + b"\xff" * 4
prefix = (output / "application-relocated.kgfw").read_bytes()[8:56]
prefix += struct.pack("<I", len(source)) + hashlib.sha256(source).digest() + bytes(range(0xA0, 0xB0)) + key_id + b"\x00"
authorization = prefix + hmac.digest(key, b"KEYGLOW-OTA-AUTH-V2" + prefix, "sha256")
stage, personalized = authenticated_artifacts(image, loader, source, authorization, slot)
assert personalized[0x3F00:] == slot and len(personalized) == 0x3F40
assert stage[:8] == b"KGOTA002" and stage[84:88] == b"\xff" * 4
assert stage[256:256 + len(image)] == image
for position in range(len(authorization)):
    bad = bytearray(authorization)
    bad[position] ^= 1
    try:
        authenticated_artifacts(image, loader, source, bad, slot)
    except ValueError:
        pass
    else:
        raise AssertionError("Mutated authorization accepted")
for position in range(len(slot)):
    bad = bytearray(slot)
    bad[position] ^= 1
    try:
        authenticated_artifacts(image, loader, source, authorization, bad)
    except ValueError:
        pass
    else:
        raise AssertionError("Mutated key slot accepted")
for field, value in [("image", image[:-1]), ("source", bytes(len(source))), ("loader", bytes(0x3F01))]:
    values = dict(image=image, loader=loader, source=source, authorization=authorization, key_slot=slot)
    values[field] = value
    try:
        authenticated_artifacts(**values)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid artifact accepted")
(output / "test-bootstrap-stage.bin").write_bytes(stage)
print("Offline authenticated assembly: all149 authorization/all64 slot corruptions, source/image/loader bounds rejected")
