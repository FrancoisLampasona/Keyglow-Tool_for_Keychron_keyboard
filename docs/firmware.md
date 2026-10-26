# Firmware and compatibility

Keyglow's Bluetooth RGB firmware targets **Keychron Q6 Max ISO encoder** only. The host application matches USB VID `3434`, PID `0861`. Layout labels are Italian; QMK supplies the physical matrix and LED geometry.

## Source and current validation

The base is [Keychron QMK revision `2b493ff95f2665db719b1e95c91babb5036e72f3`](https://github.com/Keychron/qmk_firmware/tree/2b493ff95f2665db719b1e95c91babb5036e72f3). The integration adds an indicator-report RGB decoder, deferred application and persistence, plus a battery-aware connected-idle policy. The keymap keeps the upstream ISO encoder layout.

The v3 protocol was installed and physically tested on one keyboard. A single command selected green Breathing without fn + ○, and the same setting survived a power cycle with USB unplugged. Normal typing was confirmed. This verifies that combination on that unit, not every effect or hardware revision.

The host suites cover framing, invalid and truncated data, effect transitions, persistence, legacy decoder rejection and energy-policy behavior. They use synthetic transports and memory. They cannot prove over-the-air reception, EEPROM wear characteristics, battery life, or recovery on a physical board.

## Why custom firmware is needed

The Bluetooth HID descriptor observed on the tested board exposes standard indicator outputs, but not the 32-byte Raw HID configuration channel used over USB. Keyglow encodes RGB settings into indicator reports and the custom firmware decodes them. The official firmware does not implement this protocol.

The v3 frame includes effect, hue, saturation, brightness, speed, command version and CRC16. Temporary and persistent commands are distinct. Valid commands are applied outside the LED callback; unchanged settings avoid duplicate writes. The sender restores indicator state after transmission. Close other keyboard configurators and avoid Caps/Num input during a transfer.

There is no device acknowledgement. The app cannot infer reception or successful persistence from IOKit accepting a report. Individual-key RGB, Mix, keymaps, macros and advanced configuration continue to use USB.

## Installing or building firmware

Current installation uses **USB and the STM32 DFU bootloader**. Before replacing firmware, identify the exact board variant, save its configuration, and retain a tested recovery route and appropriate original firmware. A firmware binary for a different layout is not interchangeable. A version change can reset the stored keymap and macros.

`scripts/setup-firmware.sh` prepares the pinned QMK source and Python environment. It does not download the Arm toolchain or flash hardware. Supply an Arm bare-metal compiler through `ARM_GCC_BIN` as described by the build script. The previously validated compiler was Arm GNU Toolchain 13.3.Rel1 for Darwin arm64.

`scripts/build-firmware.sh` builds the pinned, patched source and verifies the output; it does **not** flash hardware. The app build does not require these firmware tools.

Keep generated firmware and device backups out of source control. Anyone distributing a firmware image must also provide corresponding source and build information under its licenses; see [third-party notices](../THIRD_PARTY_NOTICES.md).

## Bluetooth updates are not enabled

RGB control does not provide a verified firmware-transfer channel. A usable updater also needs acknowledged chunks, integrity and target validation, recoverable staging, bootloader integration, and tested recovery from power loss. The experimental OTA code is host-test engineering work and is **not installed by the app or enabled on the keyboard**.

The present RGB firmware cannot acquire those capabilities merely through an app update. Do not send a firmware file through the RGB indicator protocol or treat successful host tests as approval to flash a bootloader.

## Wake and battery behavior

The optional Reattiva configuration lengthens the radio idle timeout. Its custom firmware policy avoids the main controller's STOP state while Bluetooth is connected and the measured battery state permits it. Radio reconnect time and macOS wake remain separate causes of delay. Battery consumption and latency need controlled measurements; no zero-latency or battery-life claim is made.
