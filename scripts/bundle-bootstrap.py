#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bundle public first-install resources only; never read any owner/private files.

Requires explicit build inputs. The unsigned loader must fit below the keyslot.
The standard image contributes only fingerprints, never a device backup.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys


def sha(data):
    return hashlib.sha256(data).hexdigest()


def bundle(destination):
    names = ['FIRMWARE_BOOTSTRAP_LOADER', 'FIRMWARE_BOOTSTRAP_REPORT', 'FIRMWARE_STANDARD_IMAGES', 'DFU_UTIL', 'LIBUSB_STATIC_LIB', 'DFU_LICENSE', 'LIBUSB_LICENSE']
    if not any(os.environ.get(key) for key in names):
        return
    if not all(os.environ.get(key) for key in names) or not os.environ.get('FIRMWARE_UPDATE_PACKAGE'):
        raise ValueError('First-install packaging requires all explicit public inputs; see docs/firmware.md')
    for key in names[:2]:
        if 'private' in Path(os.environ[key]).parts:
            raise ValueError('Private bootstrap artifacts must never be bundled')
    loader = Path(os.environ[names[0]]).read_bytes()
    if not 64 <= len(loader) <= 0x3F00:
        raise ValueError('Only an unprovisioned loader below the keyslot is allowed')
    stack, reset = struct.unpack_from('<II', loader)
    if not 0x20000008 <= stack <= 0x20010000 or stack & 7 or not reset & 1 or not 0x08000000 <= reset & ~1 < 0x08000000+len(loader):
        raise ValueError('Invalid loader vectors')
    report = json.loads(Path(os.environ[names[1]]).read_text())
    package = Path(os.environ['FIRMWARE_UPDATE_PACKAGE']).read_bytes()
    if sha(package[60:]) != report['sha256'] or struct.unpack_from('<I', package, 20)[0] != report['build']:
        raise ValueError('Target package/report mismatch')
    sources = []
    for path in os.environ['FIRMWARE_STANDARD_IMAGES'].split(os.pathsep):
        path = Path(path)
        if any(part in ('backups', 'private') for part in path.parts):
            raise ValueError('Supply original firmware images, never device readbacks')
        data = path.read_bytes()
        if len(data) >= 16 and data[-8:-5] == b'UFD':
            data = data[:-16]
        if not 32776 <= len(data) <= 131072:
            raise ValueError('Invalid standard-layout firmware length')
        sources.append(dict(name=path.name, length=len(data), vectorsSHA256=sha(data[:480]), codeSHA256=sha(data[32768:])))
    resources = destination/'Contents/Resources'
    (resources/'bootstrap-loader.bin').write_bytes(loader)
    (resources/'bootstrap-catalog.json').write_text(json.dumps(dict(schema=1,target=0x08613434,loaderSHA256=sha(loader),packageSHA256=sha(package),usbVersion=report['usb_firmware_version'],sources=sources),indent=2)+'\n')
    helpers = destination/'Contents/Helpers'; helpers.mkdir()
    helper = helpers/'dfu-util'
    shutil.copy2(os.environ['DFU_UTIL'], helper)
    links = subprocess.check_output(['otool','-L',str(helper)],text=True).splitlines()[1:]
    dependencies = [line.strip().split(' (')[0] for line in links]
    if any(not link.startswith(('/usr/lib/','/System/Library/')) for link in dependencies):
        raise ValueError('dfu-util must embed libusb and depend only on Apple libraries')
    # Reject dependencies whose deployment target exceeds the app's macOS 13 floor.
    import re
    for binary in (helper,):
        metadata = subprocess.check_output(['vtool','-show-build',str(binary)],text=True)
        minimum = re.search(r'minos\s+(\d+)',metadata)
        if minimum is None or int(minimum[1]) > 13:
            raise ValueError('USB component requires a newer macOS than the app')
    sources_dir=resources/'USB-Sources';sources_dir.mkdir()
    source_root=Path(__file__).resolve().parent.parent/'build/usb-tools/downloads'
    for name, digest in [('dfu-util-0.11.tar.gz','b4b53ba21a82ef7e3d4c47df2952adf5fa494f499b6b0b57c58c5d04ae8ff19e'),('libusb-1.0.29.tar.bz2','5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85')]:
        source=source_root/name
        if sha(source.read_bytes()) != digest: raise ValueError('USB source archive mismatch')
        shutil.copy2(source,sources_dir/name)
    shutil.copy2(os.environ['LIBUSB_STATIC_LIB'],sources_dir/'libusb-1.0.a')
    licenses=resources/'USB-Licenses';licenses.mkdir()
    shutil.copy2(os.environ['DFU_LICENSE'],licenses/'dfu-util-GPL-2.0.txt')
    shutil.copy2(os.environ['LIBUSB_LICENSE'],licenses/'libusb-LGPL-2.1.txt')
    (licenses/'SOURCES.txt').write_text('dfu-util 0.11: https://dfu-util.sourceforge.net/releases/dfu-util-0.11.tar.gz\nlibusb 1.0.29: https://github.com/libusb/libusb/releases/tag/v1.0.29\nNo upstream source modifications. libusb is statically linked into dfu-util; complete sources, the library archive and build instructions are supplied. Rebuild with scripts/build-usb-tools.sh after modifying the library, replace Contents/Helpers/dfu-util and re-sign the bundle. Retain corresponding source when distributing binaries.\n')

if __name__ == '__main__':
    bundle(Path(sys.argv[1]))
