# SPDX-License-Identifier: GPL-2.0-or-later
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("package", Path(__file__).parents[1] / "package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def image(self, length=513):
        return struct.pack("<II", 0x20010000, 0x08008009) + b"\x5a" * (length - 8)

    def test_round_trip_and_maximum(self):
        for size in [513, package.MAX_IMAGE]:
            result = package.unpack(package.pack(self.image(size), 7))
            self.assertEqual(result["length"], size)
            self.assertEqual(result["build"], 7)

    def test_each_corrupt_byte_rejected(self):
        encoded = package.pack(self.image(), 7)
        for offset in range(len(encoded)):
            corrupt = bytearray(encoded)
            corrupt[offset] ^= 1
            with self.assertRaises(ValueError):
                package.unpack(corrupt)

    def test_old_address_size_and_build(self):
        with self.assertRaises(ValueError):
            package.pack(struct.pack("<II", 0x20010000, 0x08000009) + b"\0" * 32, 7)
        for data in [b"", self.image(package.MAX_IMAGE + 1)]:
            with self.assertRaises(ValueError):
                package.pack(data, 7)
        for build in [-1, 0x100000000]:
            with self.assertRaises(ValueError):
                package.pack(self.image(), build)


if __name__ == "__main__":
    unittest.main()
