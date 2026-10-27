# Firmware and compatibility

Keyglow's Bluetooth RGB firmware targets **Keychron Q6 Max ISO encoder** only. The host application matches USB VID `3434`, PID `0861`. Layout labels are Italian; QMK supplies the physical matrix and LED geometry.

## Source and current validation

The base is [Keychron QMK revision `2b493ff95f2665db719b1e95c91babb5036e72f3`](https://github.com/Keychron/qmk_firmware/tree/2b493ff95f2665db719b1e95c91babb5036e72f3). The integration adds an indicator-report RGB decoder, deferred application and persistence, plus a battery-aware connected-idle policy. The keymap keeps the upstream ISO encoder layout.

The v3 protocol was installed and physically tested on one keyboard. A single command selected green Breathing without fn + ○, and the same setting survived a power cycle with USB unplugged. Normal typing was confirmed. This verifies that combination on that unit, not every effect or hardware revision.

The host suites cover framing, invalid and truncated data, effect transitions, persistence, legacy decoder rejection and energy-policy behavior. They use synthetic transports and memory. They cannot prove over-the-air reception, EEPROM wear characteristics, battery life, or recovery on a physical board.

The source integration also includes a bounds fix for the pinned LKBT51 SPI driver: a 64-byte read clocks four additional command bytes, so both transfer buffers need 68 bytes. The regression test reproduces the upstream out-of-bounds read and write, then checks the corrected code with ASan/UBSan. This source fix is not present in the frozen A8/B9 test images. Its connection to the observed intermittent input reports has not been established.

## Why custom firmware is needed

The Bluetooth HID descriptor observed on the tested board exposes standard indicator outputs, but not the 32-byte Raw HID configuration channel used over USB. Keyglow encodes RGB settings into indicator reports and the custom firmware decodes them. The official firmware does not implement this protocol.

The v3 frame includes effect, hue, saturation, brightness, speed, command version and CRC16. Temporary and persistent commands are distinct. Valid commands are applied outside the LED callback; unchanged settings avoid duplicate writes. The sender restores indicator state after transmission. Close other keyboard configurators and avoid Caps/Num input during a transfer.

RGB commands have no device acknowledgement. The app cannot infer RGB reception or successful persistence from IOKit accepting a report. The firmware updater uses a separate request/reply protocol. Individual-key RGB, Mix, keymaps, macros and advanced configuration continue to use USB.

## Installing or building firmware

Current installation uses **USB and the STM32 DFU bootloader**. Before replacing firmware, identify the exact board variant, save its configuration, and retain a tested recovery route and appropriate original firmware. A firmware binary for a different layout is not interchangeable. A version change can reset the stored keymap and macros.

`scripts/setup-firmware.sh` prepares the pinned QMK source and Python environment. It does not download the Arm toolchain or flash hardware. Supply an Arm bare-metal compiler through `ARM_GCC_BIN` as described by the build script. The previously validated compiler was Arm GNU Toolchain 13.3.Rel1 for Darwin arm64.

`scripts/build-firmware.sh` builds the pinned, patched source and verifies the output; it does **not** flash hardware. The app build does not require these firmware tools.

Keep generated firmware and device backups out of source control. Anyone distributing a firmware image must also provide corresponding source and build information under its licenses; see [third-party notices](../THIRD_PARTY_NOTICES.md).

## Experimental Bluetooth updater in 0.8

The app validates a relocated Q6 Max ISO `.kgfw` package, authenticates the keyboard with a fresh nonce and owner HMAC, and compares its current image hash with a local baseline. It can reuse unchanged bytes on the keyboard and transmit changed chunks, checking receipts and staging status. Completion requires a fresh authenticated identity read after reboot matching the target build, length and SHA-256. It does not update the proprietary radio firmware.

Initial provisioning requires USB/DFU and an owner key generated explicitly by the app. The key is stored in the user's Keychain and a private local bootstrap file. The personalized loader contains that secret and must never be published, bundled with the public app, or attached to issues. Public firmware packages are owner-authorized when sent; they are not publisher-signed releases or an anti-rollback system.

**A Bluetooth build 8 → 9 update completed on one Q6 Max ISO on 2026-10-27.** A fresh owner-authenticated HELLO verified build 9, its 90,632-byte length and target SHA-256; STATUS confirmed all 355 chunks and installation completed. The application image hash was `bc4074b7ac4059608a8a91d8c438f4a39dc1ef2d966cfe2759cb80761d76f53c`. USB remained disconnected. The transfer resumed across interrupted 20/80 ms attempts; finalization and post-boot verification succeeded at 20 ms. This does not establish an uninterrupted bulk transfer at 20 ms or general reliability.

After the update reboot, the user confirmed normal typing and that the selected RGB color and effect were preserved.

The READY stage also survived a real keyboard power cycle before finalization. COMMIT ended with an indicator-restoration error; after the pending-reply cooldown, a separate read-only verification proved installation. The app now automates that bounded identity reconciliation for ambiguous COMMIT transport failures, without repeating COMMIT. Typing, cancellation and invalid authentication still stop the operation. This automatic recovery is covered with the real C engine in RAM; the physical proof used the same read-only verification as a separate action.

Earlier evidence includes nonce/CRC exchanges at 80, 40 and 20 ms (100 ms return symbols), a USB bootstrap written and independently read back, and the profile restored and verified over USB. Manual amber Breathing and automatic blue Breathing at 20 ms were separately confirmed with USB unplugged.

Offline tests include authenticated staging, simulated power interruptions, wire framing, typing/disconnect cancellation and the production Swift coordinator connected to the C engine and loader in memory. These do not establish physical power-loss recovery. The initial loader-sector write is not interruption-safe, and independent BOOT0/SWD recovery has not been verified on the test unit. See [the integration notes](../firmware/ota/integration/README.md) before attempting another bootstrap.

In 0.8.2 the review reads authenticated identity and staging STATUS before enabling an update. It shows saved blocks and session flags without preparing or committing an image. Owner-key access is scoped to each explicit action; post-reboot identity remains freshly authenticated.

The host leaves a guarded 600 ms quiet interval after each reply receipt and indicator restoration, exceeding the firmware's 400 ms parser timeout. Cancellation and unexpected input remain guarded during that interval. It was present in the successful finalization, but its individual effect on earlier timeouts has not been isolated.

When a fresh STATUS reports the exact selected image as READY and complete,
0.8.2 can finalize that durable stage without repeating AUTH_BEGIN or sending
blocks. This path still requires a fresh owner-authenticated HELLO, unchanged
controller identity, exact manifest match, FINISH and COMMIT processing, and a
fresh authenticated target identity after reboot. The firmware checks the
persisted owner HMAC and image contents for both finalization commands. Selecting
replacement, an incomplete stage or a different stage keeps the full workflow.
The production Swift coordinator has passed this path against the real C
staging/loader engine in RAM, including a lost FINISH reply and wrong-key
rejection with no flash changes. The complete-stage finalization also succeeded on the physical test unit.

The stock firmware and the earlier RGB-only custom firmware cannot acquire the loader through an app update alone. Builds do not flash hardware. The app keeps RGB sending separate from firmware transfer and does not silently retry failed flash mutations.

## Wake and battery behavior

The optional Reattiva configuration lengthens the radio idle timeout. Its custom firmware policy avoids the main controller's STOP state while Bluetooth is connected and the measured battery state permits it. Radio reconnect time and macOS wake remain separate causes of delay. Battery consumption and latency need controlled measurements; no zero-latency or battery-life claim is made.

## Guided first installation in 0.10

The complete app now provides the initial controller installation without opening a web guide. It reads the actual VIA profile twice in Cable mode, binds the keyboard to its USB port, and completes explicit owner-key consent and Keychain access while the keyboard can still type. Only then does it show DFU entry. The private session retains a hash-checked owner keyslot so resuming in DFU never requires a password. In DFU it requires a single matching STM32 device on that port and the expected 256 KiB geometry. It reads the full controller twice and requires identical bytes plus a known standard-firmware vector/code fingerprint before preparing an installable image. EEPROM bytes are excluded from the firmware fingerprint, not from the backup.

Only after exact staging/loader hashes are displayed and approved does it write sector 5, read it back, write the personalized loader in sector 0, and read the full flash back. The source application and EEPROM sectors must remain identical. There is no mass erase, protection change, automatic mutation retry or automatic reset. After successful readback, the app tells the user to reconnect in Cable without Esc, verifies the expected USB version, restores supported settings and checks VIA readback. This USB version check is not an authenticated full-image hash read.

An owner-only durable journal and original backups live under `~/Library/Application Support/Keyglow/Firmware/FirstInstall`. The journal records write intent before mutations. A partial loader write can be retried using the same approved bytes **only if ROM DFU is still accessible**, the staged image is intact and source/EEPROM still match. The first loader-sector replacement remains non-atomic; physical power-loss recovery and BOOT0/SWD recovery remain unverified. Do not power-cycle after a failed loader write. No backup is deleted after completion. The current catalog accepts the official Q6 Max ISO v1.1.0 image dated March 25, 2025; unknown images are blocked, not guessed from a filename. The already installed target version is directed to Bluetooth updates.

The guided coordinator has been tested in memory for backup mismatch, wrong-device binding, source/EEPROM changes, altered artifacts, bad staging readback and partial-loader resume. Its generated bytes match the existing independently implemented Python assembler. VIA tests cover original opaque macro preservation and effect transitions that reset the color. These are software tests; the **new integrated UI has not yet performed a physical first installation**. Prior manual bootstrap evidence remains separately described above.

Bluetooth update traffic shares the indicator/reserved-report channel with typing. Both firmware and host cancel on input; flash erase also pauses scanning on this single-bank MCU. Version 0.10 therefore prominently asks for mouse-only operation, shows acknowledged byte progress, and offers explicit interruption and reviewed resume. It does not claim simultaneous lossless typing during an update.

### Bundling the first-install assistant

A basic source build remains available without firmware or USB tools and explicitly disables initial installation. To build the complete app, first build the pinned public USB tools for macOS 13:

```sh
sh scripts/build-usb-tools.sh
```

Then supply the independently built public application package, unprovisioned loader, verification report and an original standard-layout firmware image. These variables are **build-time inputs**, not runtime dependencies:

```sh
FIRMWARE_BOOTSTRAP_LOADER="$PWD/build/ota-integration/variant-b/loader-unprovisioned.bin" \
FIRMWARE_BOOTSTRAP_REPORT="$PWD/build/ota-integration/variant-b/application-verification.json" \
FIRMWARE_STANDARD_IMAGES="/absolute/path/to/q6_max_iso_encoder_v1.1.0_2503251811.bin" \
FIRMWARE_UPDATE_PACKAGE="$PWD/build/ota-integration/variant-b/application-relocated.kgfw" \
FIRMWARE_BASELINE="$PWD/build/ota-integration/variant-a/application-relocated.bin" \
DFU_UTIL="$PWD/build/usb-tools/prefix/bin/dfu-util" \
LIBUSB_STATIC_LIB="$PWD/build/usb-tools/prefix/lib/libusb-1.0.a" \
DFU_LICENSE="$PWD/build/usb-tools/src/dfu-util-0.11/COPYING" \
LIBUSB_LICENSE="$PWD/build/usb-tools/src/libusb-1.0.29/COPYING" \
zsh scripts/build-app.sh
```

The bundler rejects private/bootstrap backups, a loader overlapping the owner-key slot, target/report mismatches, unexpected dynamic libraries and USB dependencies targeting a newer macOS. It includes dfu-util/libusb licenses and exact source archives, statically links libusb into the USB helper, and signs nested binaries before sealing the app. Standard-firmware bytes contribute only public fingerprints. No owner key or personalized loader is included. Refer to [official Keychron firmware](https://www.keychron.com/pages/firmware-and-json-files-of-the-keychron-qmk-keyboards), the [DFU utility manual](https://dfu-util.sourceforge.net/dfu-util.1.html), and the included third-party notices for source provenance and redistribution obligations.
