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

Hardware evidence so far covers a nonce/CRC return-channel probe at 80, 40 and 20 ms downlink timing; the return path used 100 ms symbols. The two bootstrap phases were written and independently read back on one Q6 Max ISO. Build 8 then booted, and the saved profile was restored and verified over USB. **A complete Bluetooth A→B update has not yet been verified.** A 20 ms attempt reached at least 31,488 staged bytes before an input-report guard stopped it; the user reported no keyboard or knob activity. This does not establish the cause or a completed update. Separately, manual amber Breathing and automatic blue Breathing at 20 ms were physically confirmed with USB unplugged.

Offline tests include authenticated staging, simulated power interruptions, wire framing, typing/disconnect cancellation and the production Swift coordinator connected to the C engine and loader in memory. These do not establish physical power-loss recovery. The initial loader-sector write is not interruption-safe, and independent BOOT0/SWD recovery has not been verified on the test unit. See [the integration notes](../firmware/ota/integration/README.md) before attempting another bootstrap.

In 0.8.2 the review reads authenticated identity and staging STATUS before enabling an update. It shows saved blocks and session flags without preparing or committing an image. Owner-key access is scoped to each explicit action; post-reboot identity remains freshly authenticated.

A later controlled 80 ms attempt completed all 355 chunks (90,632 bytes) and
FINISH. The COMMIT exchange timed out. A subsequent authenticated identity read
still reported build 8, while STATUS reported build 9 complete and READY, but
neither committed nor installed. The saved stage can be resumed; this is not a
successful installation. The host now leaves a guarded 600 ms quiet interval
after each reply receipt and indicator restoration, exceeding the firmware's
400 ms parser timeout. Offline tests cover cancellation and unexpected input
during that interval; its effect on the observed timeout still needs hardware
verification.

When a fresh STATUS reports the exact selected image as READY and complete,
0.8.2 can finalize that durable stage without repeating AUTH_BEGIN or sending
blocks. This path still requires a fresh owner-authenticated HELLO, unchanged
controller identity, exact manifest match, FINISH and COMMIT responses, and a
fresh authenticated target identity after reboot. The firmware checks the
persisted owner HMAC and image contents for both finalization commands. Selecting
replacement, an incomplete stage or a different stage keeps the full workflow.
The production Swift coordinator has passed this path against the real C
staging/loader engine in RAM, including a lost FINISH reply and wrong-key
rejection with no flash changes. Hardware completion remains unverified.

The stock firmware and the earlier RGB-only custom firmware cannot acquire the loader through an app update alone. Builds do not flash hardware. The app keeps RGB sending separate from firmware transfer and does not silently retry failed flash mutations.

## Wake and battery behavior

The optional Reattiva configuration lengthens the radio idle timeout. Its custom firmware policy avoids the main controller's STOP state while Bluetooth is connected and the measured battery state permits it. Radio reconnect time and macOS wake remain separate causes of delay. Battery consumption and latency need controlled measurements; no zero-latency or battery-life claim is made.
