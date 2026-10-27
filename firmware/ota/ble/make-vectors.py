#!/usr/bin/env python3
"""Independent, synthetic wire fixtures. Contains no signed/authorized update."""
import json
import struct
import zlib
from pathlib import Path


def crc16(data):
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ (0x1021 if value & 0x8000 else 0)) & 0xFFFF
    return value


def request(op, request_id, payload=b""):
    frame = b"KGOT" + bytes([1, op]) + struct.pack("<HI", len(payload), request_id) + payload
    return frame + struct.pack("<I", zlib.crc32(frame))


def ack(op, request_id, result, flags, payload=b""):
    frame = b"KGAK" + bytes([1, op]) + struct.pack("<I", request_id) + bytes([result, flags, len(payload)]) + payload
    return frame + struct.pack(">H", crc16(frame))


entries = []


def add(name, kind, frame):
    entries.append({"name": name, "kind": kind, "frameHex": frame.hex()})


add("request-status", 1, request(3, 0x12345678))
add("request-copy", 1, request(6, 0xAABBCCDD, struct.pack("<III", 512, 1024, 4096)))
add("request-copy-full", 1, request(6, 0x10203040, struct.pack("<III", 0, 0, 98304)))
auth = bytes((i * 17 + 5) & 255 for i in range(149))
add("request-auth-synthetic", 1, request(7, 0x76543210, auth))
data = bytearray((i * 31 + 7) & 255 for i in range(256))
data[48:64] = b"KGOTKRGBKGAKKPRB"
add("request-data-max", 1, request(2, 0xFFFFFFFF, struct.pack("<I", 256) + data))
add("ack-data", 2, ack(2, 0x12345678, 0, 1))
add("ack-auth-error", 2, ack(7, 0x76543210, 11, 0))
add("ack-source-error", 2, ack(6, 0x10203040, 12, 1))
add("ack-unauthorized", 2, ack(7, 0x76543210, 0x80, 0))
add("ack-status", 2, ack(3, 0x12345678, 0, 3, bytes(range(96))))
add("ack-max", 2, ack(8, 0xDEADBEEF, 0, 15, bytes(range(128))))
commit_ack = ack(5, 0x89ABCDEF, 0, 7)
add("ack-commit", 2, commit_ack)
add("request-receipt", 1, request(0x7F, 0x89ABCDEF, bytes([5]) + commit_ack[-2:]))

Path(__file__).with_name("vectors.json").write_text(json.dumps({"schema": 1, "syntheticOnly": True, "frames": entries}, indent=2) + "\n")
