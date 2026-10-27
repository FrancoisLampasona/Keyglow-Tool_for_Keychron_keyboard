# Keyglow for macOS

Native controls for the **Keychron Q6 Max ISO**: RGB over Bluetooth, a keyboard editor over USB, and local profiles. Built with SwiftUI and AppKit for Apple Silicon and macOS 13 or later. The app interface is currently in Italian.

[Guida in italiano](docs/it.md) · [Firmware and compatibility](docs/firmware.md) · [Contributing](CONTRIBUTING.md)

Keyglow is an independent community project, not affiliated with or endorsed by Keychron. This is the macOS Q6 Max project; it is unrelated to other applications named KeyGlow.

## What works

| Feature | Connection | Status |
| --- | --- | --- |
| RGB color, brightness, speed, off and 22 effects | Bluetooth with the custom v3 firmware | Implemented; green Breathing and persistence after power-off verified on a physical Q6 Max ISO |
| Change RGB directly from the app, without fn + ○ | Bluetooth with the custom v3 firmware | Verified on that keyboard |
| Keep RGB after switching the keyboard off | Bluetooth with the custom v3 firmware | Verified; optional temporary preview is also implemented |
| Four keymap layers, knob, macros, per-key RGB, Mix and supported advanced settings | USB | Read, edit, apply and read back; availability follows device capabilities |
| Profiles, import/export, keyboard preview and foreground key test | Local app | Available without a connected keyboard |
| Quick Launch shortcuts for apps and websites | Local app | Opt-in; Keyglow must remain open |
| Automatic RGB preview while editing | Bluetooth with custom v3 firmware | Blue Breathing confirmed on the physical keyboard at 20 ms; preference remembered in 0.8.2 |
| Firmware update over Bluetooth | Custom Keyglow loader and owner key | Build 8 → 9 completed on one unit through resumed transfers; finalization and authenticated post-boot verification at 20 ms; still experimental |

Hardware validation covers **one Q6 Max ISO encoder, Italian layout**, USB VID `3434`, PID `0861`. It does not establish support for ANSI, JIS, other Keychron models, or every effect individually. Stock firmware does not interpret Keyglow's Bluetooth RGB commands. The 2.4 GHz receiver is not a configuration backend in this app.

## Download and install

Download the **[Keyglow 0.10.0 DMG](https://github.com/FrancoisLampasona/keyglow-macos/releases/tag/v0.10.0)** for Apple Silicon. Open it, drag Keyglow to Applications, then launch it there and eject the disk. The complete app includes the firmware and USB tools for the guided initial installation; no separate GitHub download is needed inside that flow.

This is an **experimental prerelease**, locally signed and not Apple-notarized. The new integrated USB installation has software coverage but has not been physically tested end to end. The first loader write is not power-loss safe; the app explains this before approval. Bluetooth updates require using only the mouse until completion.

## Build and open

Install Xcode or Command Line Tools with **Swift 6**, then run from this checkout:

```sh
zsh scripts/build-app.sh
open dist/Keyglow.app
```

The basic app build uses Apple frameworks. The optional complete first-install build bundles dfu-util and libusb; see [build instructions](docs/firmware.md#bundling-the-first-install-assistant). It produces an `arm64` application. For repeated local builds, configure [stable local signing](docs/local-signing.md) once; without a configured identity it uses an ad-hoc signature. This is **not a notarized distribution**. A developer with a signing certificate can select it with `SIGNING_IDENTITY`; signing and notarization remain separate steps.

Move the **whole `Keyglow.app` bundle** to Applications or another folder before granting permissions. Its resources travel inside the bundle; running it does not require this checkout, Python, Node, or the original build folder. Preferences and local backups belong to the macOS user, outside the app bundle. The legacy preference identifier is retained so the rename from Tastiera does not discard existing settings.

## First run and permissions

The first-run assistant separates keyboard identity, macOS access and firmware setup. It appears even when another build has already received Input Monitoring permission. Its four steps are:

1. Detect a Keychron keyboard and confirm the supported **Q6 Max ISO** identity. ANSI, other models, unknown transports and ambiguous selections cannot proceed as the supported model. Offline exploration remains available.
2. Explain and request **Input Monitoring** when needed. Returning from Settings rechecks access; an existing grant is not requested again.
3. Choose between preparing custom firmware, explicitly declaring that Keyglow firmware is already installed, or using USB configuration for now. A remembered declaration is not an authenticated firmware readback.
4. Show the appropriate next action: firmware preparation, RGB controls, or USB configuration. The in-app first-install assistant reads the real profile, completes owner-key access while typing is available, guides DFU entry, saves a full controller backup verified by two reads, prepares owner-bound images, asks approval, writes and reads back both phases, and restores the profile after restart. It never starts a flash merely by opening a page.

Reopen it from **Keyglow → Configura tastiera e accessi…**. System Bluetooth and owner-key Keychain consent remain separate, requested only by features that need them.

Apple documents the system control in [Input Monitoring settings](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac). Rebuilding an ad-hoc signed application can invalidate an earlier grant; remove the stale entry, add the current bundle, and authorize it again if access is refused. Moving a bundle does not let the app bypass macOS permission checks.

Input Monitoring is used for the HID connection. The app does not run a background keystroke recorder. Macro recording and the key test are explicit foreground actions. Quick Launch registers only the selected shortcuts. There is no analytics service, account, or cloud profile sync.

The interface adapts from a 900 × 640 window to a large desktop. Entire sidebar rows are clickable, with ⌘1–9 shortcuts. Narrow lighting windows prioritize color controls and offer a collapsible physical keyboard preview. The **Finestra** menu provides compact and comfortable sizes; window placement is remembered. Contextual footers appear only in configuration editors. Firmware keeps its selected file and review when navigating between pages.

Profiles separate personal configurations, automatic recovery copies and a restorable trash. Existing schema-1 profiles remain compatible. Loading a profile or browsing RGB editor tabs does not send RGB changes; per-key/Mix activation is explicit and their edits remain USB-only.

## Everyday RGB control

With the custom v3 firmware installed, open **Illuminazione**, choose a color and effect, keep **Salva nella tastiera** enabled, and select **Applica e salva RGB** (**Invia ora** when automatic preview is enabled). No keyboard shortcut is needed. Disable saving for a temporary preview.

A manual transfer takes about five seconds. Avoid Caps Lock and Num Lock during it, then wait at least two seconds after completion before switching the keyboard off. Opening the app does not send RGB settings.

In 0.8.2, **Anteprima sulla tastiera** enables automatic Bluetooth sending while editing. It starts disabled for new users and remembers your choice across launches. Opening the app still sends nothing: a new edit is required. It debounces changes and keeps only the latest pending setting while a command is in flight. Preview commands are temporary; with saving enabled, the final setting is saved after editing settles. Leaving the page discards unsent changes. The rapid 20 ms timing is experimental. Blue Breathing was physically confirmed with USB unplugged, after changing the color without clicking Apply. Automatic sending does not mean instantaneous response.

The RGB transport uses HID indicator reports and has **no device acknowledgement**. A completed RGB send means macOS accepted the reports; confirm the visible result on the keyboard. The saved green Breathing setting has been tested through a real power cycle with USB disconnected. Other effects and persistent off have automated coverage but have not all been tested physically. Firmware updates use a separate acknowledged protocol.

For USB editing, select **Leggi tastiera**, edit the local draft, save a profile, then apply. The app checks for conflicting changes and reads settings back after writes. Close other keyboard configurators while applying settings.

## Firmware and wake behavior

The custom firmware is based on Keychron QMK commit [`2b493ff95f2665db719b1e95c91babb5036e72f3`](https://github.com/Keychron/qmk_firmware/tree/2b493ff95f2665db719b1e95c91babb5036e72f3). Initial installation requires **USB/DFU**. Version 0.8 adds an experimental authenticated Bluetooth updater for keyboards already provisioned with the Keyglow loader and owner key. Read [the firmware guide](docs/firmware.md) for its current hardware validation and recovery limits.

The optional **Reattiva** policy reduces keyboard-side sleeping while connected, subject to battery safeguards. Its effect on wake latency and battery life has not been measured. It cannot promise an instant Bluetooth connection while macOS is starting or waking.

## Development

The experimental staging engine and its limits are documented in [firmware/ota](firmware/ota/README.md).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local test commands and firmware source setup, and [build cleanup](docs/build-cleanup.md) for archiving old apps without duplicate Launchpad entries. CI builds the app and runs host tests; it cannot validate Bluetooth reception, macOS consent dialogs, power-cycle persistence, or hardware recovery.

Device backups, personal macros, local profiles, research captures, build outputs and downloaded vendor bundles are excluded from the public source. Please do not attach them to issues.

## License

**GPL-2.0-or-later**. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the QMK/Keychron source provenance and distribution obligations. Keychron names identify compatible hardware and are not project branding.

## DMG distribution

The experimental `0.10.0` Apple Silicon release includes a DMG with drag-to-Applications installation. It is locally signed, **not Apple-notarized**; the local development certificate is not a trusted Developer ID on another Mac. The app retains the same bundle identifier and stable local requirement on the development Mac. Security approvals remain user-controlled.

To package a verified complete build, install `scripts/packaging-requirements.txt` in an isolated Python environment, then run `scripts/package-dmg.py`. It copies only `dist/Keyglow.app`, an Applications link and installation notes. `scripts/package-firmware-source.py` produces the corresponding frozen firmware source archive to distribute alongside it. Never add private bootstrap images or device backups to a release.
