# Relocated Q6 Max application integration

This isolated QMK application retains RGB/power behavior from0.6, adds a
staging-only flash driver and relocation, and binds the experimental LED downlink
and reserved-byte Bluetooth return path. Owner HMAC authorization is mandatory.
No request can mutate flash without a valid private keyslot and authorization.
On 2026-10-27, both USB bootstrap phases were written and independently read
back on one Q6 Max ISO. The loader installed build 8, which booted normally; the
saved profile was restored and verified over USB. The complete Bluetooth A→B
update, physical power-loss recovery and independent BOOT0/SWD recovery remain
unverified. Short nonce/CRC exchanges do not establish reliable bulk delivery.
Nothing here is flashed or copied into `dist/` by a build.

## Build and inspect

```sh
zsh scripts/setup-firmware.sh
python3 firmware/apply-qmk-patch.py build/qmk-firmware
# Point to the bin directory of the independently installed Arm GNU 13.3.Rel1.
export ARM_GCC_BIN="/absolute/path/to/arm-gnu-toolchain/bin"
sh firmware/ota/integration/build.sh
sh firmware/ota/integration/test.sh
```

The setup script fetches Keychron QMK revision
`2b493ff95f2665db719b1e95c91babb5036e72f3`, initializes the dependencies pinned by
that revision and installs the Python requirements from `firmware/requirements.txt`.
It does not obtain the Arm compiler or flash hardware. The patcher applies this
repository's shared RGB/power hooks; the isolated builder then checks them and
generates only its own keymap. See the [source and dependency licenses](../THIRD_PARTY.md)
and preserve the pinned checkout's dependency notices when distributing binaries.

To reproduce the separate A8/B9 candidates from the same source checkout:

```sh
KEYGLOW_OTA_BUILD=8 KEYGLOW_OTA_OUTPUT="$PWD/build/ota-integration/variant-a" \
  sh firmware/ota/integration/build.sh
KEYGLOW_OTA_BUILD=9 KEYGLOW_OTA_OUTPUT="$PWD/build/ota-integration/variant-b" \
  sh firmware/ota/integration/build.sh
KEYGLOW_OTA_OUTPUT="$PWD/build/ota-integration/variant-a" \
  sh firmware/ota/integration/test.sh
KEYGLOW_OTA_OUTPUT="$PWD/build/ota-integration/variant-b" \
  sh firmware/ota/integration/test.sh
sh macOS/Tests/FirmwareEngine/run.sh
```

These commands build and test locally. They do not provision a real owner key,
install firmware, or read a device. The final test joins the production Swift
coordinator to the C engine/loader using memory-backed flash and a public test key.

`KEYGLOW_OTA_BUILD` selects the compiled build number (default 8).
`KEYGLOW_OTA_OUTPUT` selects a separate absolute output folder. QMK's own
timestamp generator is overridden only for isolated `generate-version-h` calls.
The deterministic release identity is 2026-10-27T00:00:00Z plus the build number
in seconds; it is not a claim about compilation wall time. A/B therefore report
`v1.1.1 2026-10-27-00:00:08` and `v1.1.1 2026-10-27-00:00:09` over USB. Their same
date preserves VIA's date-based EEPROM magic across A→B. HELLO independently
reports build 8/9 and full image SHA. The verifier checks the compiled timestamp
and HELLO's linker image-length symbol against all loadable image bytes.

The build expects the pinned QMK checkout and existing RGB v0.6 shared hooks. It
checks those hooks without editing them. It writes only the separate
`keyglow_ota` keymap and `build/ota-integration/` outputs, and does not rebuild the
installed `tastiera_bt` keymap. ELF-only compilation avoids QMK's repository-root
firmware copy/DFU suffix step.

The linker places all vectors/code/constants/data initializers in
`0x08008000..0x0801FFFF` (96 KiB). Sector 1 remains dedicated to the existing
EEPROM. Compile assertions preserve its original backing/logical sizes,
6144/3072 bytes, at `0x08004000`; the entire physical 16 KiB sector is excluded
from OTA writes. The matrix process stack is increased to 4096 bytes for nested
receiver/hash calls. Static stack usage files are emitted; this does not replace
a hardware stack-watermark test.

`verify.py` checks every loadable ELF segment, all interrupt vectors, application
size/addresses, EEPROM linker bounds, retained receiver symbols, and RAM placement
of flash-busy code. It also rejects direct helper calls from that code into flash.
The resulting `application-verification.json` contains exact sizes and SHA-256.

## Adapter boundary

The public interface is `qmk_ota_adapter.h`:

- The BLE transport reassembles a complete KGOT frame and calls
  `keyglow_ota_submit_frame`. Maximum 276 bytes; only one transaction is queued.
- `keyglow_ota_task`, called by the foreground matrix scan, processes the request.
  It never runs flash operations in an interrupt handler.
- `keyglow_ota_peek_reply` returns the stable 120-byte reply. The transport may
  repeat it until delivery is known; it must not interpret a local enqueue as ACK.
- `keyglow_ota_reply_delivered(request_id)` releases the reply. A successful COMMIT
  schedules a reset after 1500ms only after this explicit delivery notification. A missing
  notification does not trigger an immediate reset. A later physical reset may
  install an already committed image, since commit is durable authorization.
- A lost reply expires after60 seconds, allowing reconnect/status recovery and
  preventing indefinite sleep suppression. Held keys defer mutation for at most
  30 seconds, then produce a busy response without writing.
- `keyglow_ota_cancel_pending` drops queued/COPY/reply state without writes after
  typing or disconnect. Completed chunks remain. It does not revoke a durable
  COMMIT and cannot retract an acknowledged reset.
- COPY covers up to96KiB but processes only one256-byte chunk per foreground
  poll, rechecking idle/power/authentication; total transaction deadline60s.
- `keyglow_ota_set_authorizer` optionally adds a trusted restrictive policy.
  Absence of that callback permits policy but never bypasses the mandatory
  provisioned owner key, HMAC and source binding. SHA256 alone is not approval.
- HELLO8 is read-only, computes current image SHA and returns owner HMAC over the
  request nonce and identity. It works without a staging session.

`ble/qmk_ble_ota.c` runs before RGB hooks. It quarantines recognized KGOT traffic
and aborted transfers until a quiet gap, cancels on typing/disconnect, and sends
reserved-byte reports only with physical/logical keys and report queues empty.
It does not inject ordinary keys, consumer keys or mouse input. There are no
vendor GATT writes. See `ble/README.md` for the bounded transport and tests.

## Flash execution and limits

The application driver permits reads of controller flash, programs only staging,
and can erase only sector 5. It cannot erase/program the application, loader, or
EEPROM. Installation of sectors 2–4 remains the loader's job.

The STM32F401 has one flash bank: a sector erase can stall execution from flash.
All busy-time functions and their constants are linked into ChibiOS `.ramtext`,
copied into SRAM by normal startup. The driver masks ordinary interrupts for
each hardware operation, programs with x8 access, services an already enabled
watchdog, and flushes flash caches after completion. DWT cycle deadlines are
100 ms per byte program and 8 seconds for the staging erase. If busy exceeds a
deadline, code requests a system reset **from RAM** rather than returning into
busy flash. These are software bounds, not measured erase timings.

The receiver requires no held keys and 500 ms idle before mutations. It requires
USB power or a real, settled battery reading of at least 3800 mV. These are
conservative preliminary policy checks, not battery qualification or a guarantee
against voltage collapse.

During a long erase, normal keyboard scanning and interrupt-driven processing
pause. RTOS ticks may be lost; the DWT deadline remains independent of SysTick.
Bluetooth module buffering and reconnection behavior are untested. A real updater
must announce the busy period, stop sending, tolerate the pause and explicitly
verify its result. Continuous, lossless typing during erase is not promised.

## Offline bootstrap preparation

Default `assemble.py` creates an unprovisioned loader, package and an explicit
`bootstrap-plan.json` with no phases. A blank keyslot is denied by the loader;
these default outputs are not installable bootstrap artifacts. Old unsigned
bootstrap files generated by earlier versions are removed from the output.

`provision.py` takes an existing private64-byte owner keyslot, full256KiB
read-back and its expected SHA, matching current standard-layout firmware,
reviewed target package and unprovisioned loader. It verifies vectors/code while
excluding the EEPROM hole, binds actual source bytes and produces:

1. `bootstrap-phase1-staging.bin`: the complete relocated application with sealed,
   authenticated format2 ready/committed metadata, for sector5 at0x08020000.
2. `bootstrap-phase2-loader-private.bin`: the loader with private keyslot for
   sector0, installed only after staging has been independently read back.

The provisioner writes only a new0700 directory under
`build/ota-integration/private`, with0600 files. It never generates an owner key,
uses Keychain, publishes data or accesses hardware. The personalized loader
contains a secret: never publish or bundle it. No flat image spanning the EEPROM
hole and no flash command is generated. Keeping
the new application staged before replacing the loader allows its first boot to
perform the already-tested resumable install. The bootstrap test passes these
actual generated bytes into the portable installer and compares the installed
application while checking loader/EEPROM preservation.

**Initial replacement of sector 0 is not power-cut safe.** Establish a proven
BOOT0/SWD recovery path, backups, stable power and explicit approval of the exact
artifacts before any provisioning. Retain ROM DFU throughout both verified phases.
Once the loader is correctly installed, later application installs are resumable;
that does not make the initial loader replacement atomic or hardware qualified.

These are owner-authorized experimental artifacts, not publisher-signed releases.
The observed USB bootstrap does not validate a complete Bluetooth update or
physical recovery after interruption. Tests use a clearly public deterministic
fixture key only; the provisioner has no default or fixture key.
