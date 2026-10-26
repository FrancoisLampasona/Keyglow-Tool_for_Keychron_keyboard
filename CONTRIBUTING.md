# Contributing to Keyglow

Start with an issue describing the behavior, keyboard variant, connection mode and relevant firmware version. Distinguish an observed hardware result from a simulated test. The supported target is currently the Q6 Max ISO encoder; adding another board needs its own definition, capability checks and hardware validation.

## App development

Use an Apple Silicon Mac, macOS 13 or later, and Xcode/Command Line Tools with Swift 6. Node.js is needed only for the independently generated Launcher import/export test fixtures; it is not an app runtime dependency.

```sh
zsh scripts/test-protocol.sh
zsh scripts/test-energy.sh
zsh scripts/test-via.sh
zsh scripts/test-workspace.sh
zsh scripts/test-quick-launch.sh
zsh scripts/test-launcher-backup.sh
zsh scripts/test-launcher-macros.sh
sh macOS/Tests/Onboarding/run.sh
zsh scripts/build-app.sh
```

Run the tests relevant to a change before opening a pull request. Keep transport errors, device acknowledgements and visible hardware results distinct in UI wording.

All app resources must resolve through the application bundle. User data must use macOS user storage, not the source tree or current working directory. Preserve preference compatibility when renaming the app. Changes to permission handling must query the current macOS authorization state and keep consent under the user's control.

## Firmware tests

The complete host suite uses a pinned Keychron QMK checkout. It reads and patches snippets in memory; it does not flash a device.

```sh
zsh scripts/setup-firmware.sh --source-only
sh firmware/test.sh
make -C firmware/ota test
```

Do not replace an existing checkout with uncommitted work. The OTA suite exercises the experimental staging/installer core with simulated flash failures; it does not enable Bluetooth updating. Firmware compilation also requires an Arm toolchain; see [the firmware guide](docs/firmware.md). Host tests are not evidence that an update is safe to install on hardware.

## Pull requests

Explain the problem, resulting behavior, and checks performed. Include a screenshot for a visible UI change, using a synthetic profile. Include a recovery and interrupted-transfer analysis for anything that writes flash. Keep an unverified transport or boot path disabled in user-facing builds.

Never commit device backups, real macro contents, account names from logs, Bluetooth addresses, serial numbers, signing keys, certificates, or local permission databases. Use synthetic test data and review the staged files before pushing.

Contributions are provided under GPL-2.0-or-later, consistent with the project and its QMK-derived data. Preserve attribution and identify the source and license of any new third-party material. See [SECURITY.md](SECURITY.md) for vulnerability reporting.
