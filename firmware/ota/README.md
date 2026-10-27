# Keyglow OTA engine — experimental

This directory implements and tests a firmware staging/install engine for the
**Q6 Max ISO, STM32F401xC, 256 KiB flash / 64 KiB RAM**. It is not a working
Bluetooth updater qualified for release. The preserved0.6 firmware and production
RGB protocol are unchanged. Build scripts do not install this code on hardware.

An isolated application now binds the LED downlink and reserved-byte report
return path. A short hardware nonce/CRC exchange proved the return path on one
keyboard. On 2026-10-27, both USB bootstrap phases were independently read back,
the loader installed relocated build 8, and the saved profile was restored and
verified over USB on that Q6 Max ISO. A complete Bluetooth A→B update remains
unverified, as do physical power-loss recovery and independent BOOT0/SWD recovery.
Successful macOS writes alone are not
acknowledgements. Initial USB installation provisions the custom loader and a
private owner key; no universal secret or public fixture key is used for devices.

## What is implemented

- A portable C receiver: target/address/size validation, 256-byte chunks,
  persistent missing-chunk bitmap, duplicate detection, safe retransmission,
  SHA-256 integrity verification, ARM vector checks, explicit finish and commit.
- Bounded COPY from the current application, with256-byte durable steps and
  full96KiB coalesced commands. The target still requires its complete SHA256.
- Owner HMAC-SHA256 authorization binding target manifest, current source,
  nonce/key ID and replacement policy. A nonce-bound HELLO authenticates current
  image identity. Blank/missing keys and unsigned legacy staging fail closed.
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
- A fully compiled isolated QMK application with vectors at `0x08008000`,
  staging-only flash driver, and experimental transport. See `integration/`.

## Flash layout

| Sector | Address range (inclusive) | Use |
|---|---|---|
| 0 | `08000000..08003FFF` | Loader; final256 bytes reserved for private owner slot |
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

At boot, the secure installer authenticates format2 and validates staging
**before any application erase**. It verifies the source digest and records a
durable install-start checkpoint; subsequent interrupted attempts can resume
without hashing the partly erased old application. If the
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
corruption, watchdog timing, sustained radio behavior, or electrical faults.
HMAC provides owner authorization, not publisher identity or physical extraction
resistance; there is no monotonic anti-rollback policy. All these
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
The authenticated loader fits below the reserved owner slot; exact image sizes
and hashes are emitted by the isolated integration build. A successful compile
is not a hardware qualification. Default assembly emits no authenticated
bootstrap until an existing private owner slot and verified current dump are
explicitly supplied to `integration/provision.py`.

See [the integration build instructions](integration/README.md#build-and-inspect)
for the pinned source setup, shared RGB patches and exact A8/B9 build commands.

Offline package operations for an already relocated application:

```sh
python3 firmware/ota/package.py create app-relocated.bin update.kgfw --build 7
python3 firmware/ota/package.py verify update.kgfw
```

Creation refuses to overwrite an existing file. This does not upload or install.
See [PROTOCOL.md](PROTOCOL.md) for the wire/storage contract and
[THIRD_PARTY.md](THIRD_PARTY.md) for source dependencies and licenses.
