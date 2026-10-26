# Keyglow OTA engine — experimental, not connected to Bluetooth

This directory implements and tests a firmware staging/install engine for the
**Q6 Max ISO, STM32F401xC, 256 KiB flash / 64 KiB RAM**. It is not a working
Bluetooth updater. The installed 0.6 firmware and the production RGB protocol
are unchanged. No code in this directory is installed by the app or build script.

The missing dependency is a verified bidirectional host↔keyboard transport. The
current Bluetooth LED carrier can send RGB commands but has no keyboard ACK.
Successful macOS writes are not acknowledgements of staged or installed data.
The engine must not be exposed as an available updater until a real transport,
relocated application, initial loader installation, and hardware qualification
exist. An initial USB installation is required to provision a custom loader.

## What is implemented

- A portable C receiver: target/address/size validation, 256-byte chunks,
  persistent missing-chunk bitmap, duplicate detection, safe retransmission,
  SHA-256 integrity verification, ARM vector checks, explicit finish and commit.
- A loader installer that checks staging before erasing the active application,
  copies only application sectors, verifies the result, and can restart after an
  interrupted erase/write. It preserves staging until installation completes.
- A bounded, CRC-checked request/reply codec. This accepts complete frames; it is
  transport independent, and does not emit keyboard, consumer, or mouse input.
- An offline `.kgfw` package builder/validator. It rejects the old unrelocated
  image. SHA-256 is integrity checking, **not publisher authentication**.
- An STM32F401 loader linked into sector 0 using the ST/CMSIS headers from QMK.
  Its flash driver executes busy polling from RAM, uses byte programming,
  services an already running watchdog, flushes flash caches, and limits writes.
- A separate QMK application linker layout with vectors at `0x08008000`. This
  layout is supplied for integration; no complete QMK application using it has
  been built or hardware tested in this change.

## Flash layout

| Sector | Address range (inclusive) | Use |
|---|---|---|
| 0 | `08000000..08003FFF` | 16 KiB loader |
| 1 | `08004000..08007FFF` | Existing 16 KiB EEPROM, never touched by OTA |
| 2–4 | `08008000..0801FFFF` | Relocated application, maximum 96 KiB |
| 5 | `08020000..0803FFFF` | 128 KiB staging |

The first 256 staging bytes hold the manifest, state, and chunk bitmap. The new
application follows at `0x08020100`. This is a staging design, not dual active
slots: interruption resumes the new installation; it does not restore the old
application. A valid but broken new program needs ROM DFU recovery.

Sector 0 and sector 1 are excluded by software write bounds. **Hardware WRP is
not enabled.** The prototype never changes option bytes, RDP, or WRP. Its recovery
branch enters the STM32 ROM bootloader; this is still USB recovery, not Bluetooth.

## Durable state and failure model

`begin` erases only sector 5, verifies the erase, writes an immutable CRC-checked
manifest, and seals it last. The manifest contains format, exact board target
`0x08613434`, application base, length, build number, chunk size, and SHA-256.
With `replace=false`, the same manifest resumes without erasing. An explicit
`replace=true` erases and restarts an uncommitted session, including the same
manifest after an incorrect chunk caused a digest failure. A committed but
uninstalled session cannot be replaced, even by an identical manifest. An
identical already-installed image returns success without erasing again.

Each received chunk is read back before its bitmap bit is cleared. Repeated
identical chunks succeed without rewriting. A partially programmed chunk can be
retried if every requested bit transition remains `1→0`; conflicting data is
rejected. `finish` requires every chunk, the digest, and valid initial stack/reset
vectors. `commit` verifies again and clears a dedicated single-bit state marker.

At boot, the installer validates staging **before any application erase**. If the
active digest already matches, it only records completion. Otherwise it erases
sectors 2–4, copies, verifies, and records completion. A restart repeats that
process using the intact staging sector. It never marks an unverified image as
installed, and never boots a partially installed image after a detected error.

The tests model power loss before, after 1/2/3 bytes, after all 4 bytes, and with
two complementary partial-bit patterns for each word callback. The target driver
implements that callback as four x8 writes. Erase faults affect fractions or
partial bits of the addressed sector. The model assumes an interrupted operation
affects only its addressed flash word/sector.
They do not qualify real brownouts, supply margins, flash wear, arbitrary memory
corruption, malicious packages, watchdog timing, radio behavior, or electrical
faults. A hash is not a signature; there is no anti-rollback policy. All these
limits matter before enabling an updater in a released app.

## Build and verification

From the repository root:

```sh
make -C firmware/ota test
```

Requires a C11 compiler with AddressSanitizer/UndefinedBehaviorSanitizer, `make`,
and Python 3. No device or network is accessed. Tests cover every mutation in a
1031-byte receive/install transaction, plus a 96 KiB boundary image, malformed
frames/packages, wrong target/address/vectors, corrupted image, and idempotence.

Optional compile-only loader check:

```sh
sh firmware/ota/stm32f401/build.sh
```

The script defaults to the local pinned QMK and ARM toolchain under `build/`.
Set `QMK_ROOT` and `ARM_TOOLCHAIN` (compiler prefix ending `arm-none-eabi-`) to
other paths; relative paths resolve from `firmware/ota`. It outputs only a local
ignored ELF/map, deliberately no flashable `.bin` or programming command.
Measured loader image: 2820 bytes, including 340 bytes copied into RAM; fits the
16 KiB region. A successful compile is not a hardware qualification.

Offline package operations for an already relocated application:

```sh
python3 firmware/ota/package.py create app-relocated.bin update.kgfw --build 7
python3 firmware/ota/package.py verify update.kgfw
```

Creation refuses to overwrite an existing file. This does not upload or install.
See [PROTOCOL.md](PROTOCOL.md) for the wire/storage contract and
[THIRD_PARTY.md](THIRD_PARTY.md) for source dependencies and licenses.
