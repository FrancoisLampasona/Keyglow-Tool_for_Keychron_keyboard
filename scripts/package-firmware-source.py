#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Corresponding public source for frozen A8/B9 images, never working-tree files."""
from pathlib import Path
import io
import subprocess
import tarfile

ROOT=Path(__file__).resolve().parent.parent
FIRMWARE_REV='12930ce'
QMK_REV='2b493ff95f2665db719b1e95c91babb5036e72f3'
output=ROOT/'dist/Keyglow-firmware-A8-B9-source.tar.gz'
repos=[(ROOT,FIRMWARE_REV,'keyglow-firmware/'),(ROOT/'build/qmk-firmware',QMK_REV,'upstream/qmk/')]
for relative in ('lib/chibios','lib/chibios-contrib','lib/printf'):
    path=ROOT/'build/qmk-firmware'/relative
    revision=subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD'],text=True).strip()
    expected=subprocess.check_output(['git','-C',str(ROOT/'build/qmk-firmware'),'ls-tree',QMK_REV,relative],text=True).split()[2]
    if revision != expected: raise ValueError('Dependency revision mismatch')
    repos.append((path,revision,'upstream/qmk/'+relative+'/'))
readme='''Corresponding source for Keyglow frozen controller builds 8 and 9 and unprovisioned loader.

Keyglow firmware revision: 12930ce (before the later LKBT51 bounds patch).
QMK revision: 2b493ff95f2665db719b1e95c91babb5036e72f3.
All source used for the ARM target, including ChibiOS, ChibiOS-contrib and printf,
is supplied under upstream/qmk with original licenses. Nothing comes from the
user's working tree. No keys, profiles, device readbacks or personalized loaders.

Rebuild using the instructions in keyglow-firmware/firmware/ota/integration/README.md
and Arm GNU Toolchain 13.3.Rel1. Start in keyglow-firmware, run scripts/setup-firmware.sh
(to create the pinned Git working copy and Python environment), apply its
firmware/apply-qmk-patch.py, then build separately with KEYGLOW_OTA_BUILD=8 and =9.
The upstream source archive is included for inspection and license compliance;
the normal setup command fetches Git metadata needed by revision checks.

B9 application SHA256: bc4074b7ac4059608a8a91d8c438f4a39dc1ef2d966cfe2759cb80761d76f53c
Neither frozen image contains the later source-only LKBT51 bounds patch.
The macOS application has its own current source in the GitHub release source archive.
USB tool source archives and licenses are also inside Keyglow.app/Contents/Resources.
'''
with tarfile.open(output,'w:gz') as target:
    data=readme.encode();entry=tarfile.TarInfo('README.txt');entry.size=len(data);entry.mode=0o644;target.addfile(entry,io.BytesIO(data))
    for path,revision,prefix in repos:
        args=['git','-C',str(path),'archive','--format=tar','--prefix='+prefix,revision]
        if revision == QMK_REV:
            roots=subprocess.check_output(['git','-C',str(path),'ls-tree','--name-only',revision],text=True).splitlines()
            args += [name for name in roots if name not in ('keyboards','docs','.github')]
            args += ['keyboards/keychron/common','keyboards/keychron/q6_max']
        process=subprocess.Popen(args,stdout=subprocess.PIPE)
        with tarfile.open(fileobj=process.stdout,mode='r|') as source:
            for entry in source:
                target.addfile(entry,source.extractfile(entry) if entry.isfile() else None)
        if process.wait() != 0: raise RuntimeError('Source archive failed')
print(output)
