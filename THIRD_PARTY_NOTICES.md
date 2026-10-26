# Third-party notices

Keyglow source code is distributed under **GNU GPL version 2 or, at your option, any later version** (`GPL-2.0-or-later`), unless a file states otherwise. The complete GPL version 2 text is in [LICENSE](LICENSE).

## Keychron QMK firmware and keyboard definition

- Upstream: [Keychron/qmk_firmware](https://github.com/Keychron/qmk_firmware), derived from [QMK Firmware](https://github.com/qmk/qmk_firmware).
- Pinned revision: `2b493ff95f2665db719b1e95c91babb5036e72f3`.
- License: GPL-2.0-or-later for the QMK-derived material used here. Upstream dependencies retain their individual notices and licenses.
- `macOS/Sources/KeyboardDefinition.swift` and `macOS/Resources/q6-max-iso.json` contain generated keyboard geometry, matrix, LED mapping, factory keymap and keycode data derived from this revision. The resource records source provenance; the generator is `scripts/generate-keyboard-definition.py`.
- `firmware/` contains the Bluetooth RGB protocol, QMK integration and tests. The patcher modifies the pinned upstream tree when building; the upstream checkout is downloaded separately and is not vendored in this repository.
- Host integration tests extract small functions from the pinned upstream checkout at test time to exercise the real renderer and power policy. They do not require a connected keyboard.

Copyright in upstream material remains with its authors. Preserve upstream notices when generating or distributing modified firmware. If distributing a compiled firmware image, provide its corresponding source, patches and build instructions, including the exact upstream revision and dependency revisions required for that image. A pointer to an unrelated newer checkout is not a substitute for corresponding source.

## macOS platform

The app uses Apple system frameworks including AppKit, SwiftUI, IOKit, Carbon and CryptoKit. Apple SDKs and frameworks are not redistributed in the source repository. Their names and trademarks remain those of their owners.

## Artwork and references

The generic glowing-key app icon was generated and edited for this project. It does not contain a Keychron logo. Keyboard legends and the illustrated Italian layout identify the supported hardware; private reference photographs are not distributed.

Keychron Launcher was studied for interoperability. `macOS/Tests/LauncherMacros/keycode-values.json` records a bounded table of keycode names and numeric values, with a source URL and capture hash, for independently generated test fixtures. It contains no vendor implementation. Downloaded Launcher JavaScript, extracted vendor bundles, and private analysis captures are not included. The project does not claim ownership of Keychron's website, product images, trademarks, or firmware dependencies.

Keyglow for macOS is independent of Keychron and of other projects with the name KeyGlow. No code or branding is taken from those similarly named projects.

The isolated experimental OTA loader has additional optional build dependencies documented in [firmware/ota/THIRD_PARTY.md](firmware/ota/THIRD_PARTY.md); it is not included in the macOS app binary.
