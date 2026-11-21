# Screenshot provenance

The files listed first were captured directly from installed Keyglow apps on 2026-10-27. They are unretouched native app captures, not generated mockups.

- `lighting.png`: version 0.10.1, lighting editor, sidebar battery entry and local Q6 Max ISO preview.
- `keymap.png`: version 0.10.0, keymap editor with the local default draft.
- `guided-install.png`: version 0.10.0, initial step of the integrated firmware assistant.

No screenshot proves a physical firmware write or RGB receipt. Personal profiles, macros, keys and device identifiers are excluded. See [DMG validation](../dmg-validation.md) for the test scope.

The following files are different: they are drawn offscreen from the app's own SwiftUI views by `macOS/Tests/Onboarding/preview.sh`, in version 0.12.0, with synthetic states and no keyboard connected. They show the real layout, not a session on real hardware.

- `setup-keyboard.png`, `setup-access.png`, `setup-firmware.png`: steps of the setup guide.
- `languages-fr.png`: the first step of the setup guide in French.
- `firmware-installed.png`: the Installed Firmware card with a synthetic USB reading.
