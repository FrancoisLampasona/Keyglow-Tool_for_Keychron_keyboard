# DMG and first-run validation — 2026-10-27

Tested release: **Keyglow 0.10.0, build 22**, Apple Silicon.

DMG SHA-256: `c44a62e019c07aa19636eff4b9d981487fc2be3c7f8877f5725b2cd1a60ed406`.

## Completed on the Mac

- Downloaded the published DMG from the renamed GitHub repository and matched the release digest.
- Mounted it read-only; installed its exact app bundle at `/Applications/Keyglow.app`. Remote Finder dragging did not complete the copy, so the identical bundle was copied with the macOS file-copy tool. Every file was compared and the signature verified.
- Saved private copies of existing app preferences, profiles and recovery files before testing. No personal data was included in screenshots or committed.
- Started the distributed app with temporarily empty app preferences. The first-run assistant appeared automatically.
- Recognized one Q6 Max ISO over USB, displayed the access explanation, reused an existing valid Input Monitoring grant, explained custom firmware requirements, and opened the in-app installation assistant.
- Read the keyboard configuration twice over USB. The first-install assistant correctly detected the already installed target and refused to reinstall it.
- Restored and compared all original app preferences exactly after the first-run test.
- Captured the actual installed application's lighting, keymap and guided-install pages for the README. They use a local default draft, not an invented hardware result.

## Not established by this test

**A complete first firmware installation was not performed.** This keyboard already had the custom loader and build 9. Testing the stock-to-Keyglow path would require a separately approved return to stock firmware after a complete controller backup.

Two attempts to enter DFU with Esc did not enumerate an STM32 DFU device; the Mac continued to identify the normal Q6 Max. The physical reset-button attempt was deferred by the owner. No firmware, loader, protection bits or factory-reset command was written. The second Esc attempt changed keymap, lighting and sleep settings. The saved pre-test VIA snapshot was restored using the production transport; two full readbacks then matched that snapshot exactly, including macros. Firmware was unchanged. The app preferences also matched the pre-test copy exactly.

This was a clean **app-preferences** test on an existing macOS account. Input Monitoring, Keychain and local certificate trust were not reset. It does not prove the consent flow on a new macOS account or another Mac.

Gatekeeper's read-only assessment returned **rejected**. The release has a stable local signature, not a trusted Developer ID/notarization. Successful launch on the development Mac must not be described as a frictionless installation on a fresh Mac. No global protection was disabled and no quarantine flag was removed for this test.

The in-memory installer tests and previous manual bootstrap/OTA evidence remain separate; see [firmware validation and limits](firmware.md).

## Data and cleanup

Private recovery material is retained outside the checkout under the user's Application Support directory. Generated build outputs and the duplicate checkout app can be removed without moving or resetting the installed app's preferences. Only `/Applications/Keyglow.app` is retained as the active app. The repository retains source, tests, licenses, public documentation and README screenshots.

## Battery update — 0.10.1, build 23

The battery extension uses the existing read-only CoreBluetooth identity and Battery Level parser. It does not modify the controller firmware. Automatic refresh requires an existing Bluetooth authorization, one detected Q6 Max, an active app and no competing operation; the Firmware page pauses it. An explicit read can request the separate Bluetooth permission. Values outside 0–100 are rejected, reads older than three minutes are marked previous, and disconnected/Cable mode has no percentage. No charging or runtime estimate is inferred.

Identity/parsing and freshness/refresh-gating tests passed. The native sidebar and Cable explanation were inspected at 1400 × 900 and 900 × 640. A fresh physical percentage read for this build remains pending a Bluetooth-mode test; screenshots do not substitute for it.

The complete 0.10.1 DMG was mounted read-only and its files matched the installed app, with strict signature verification and bundled USB-helper launch. A separate signing test confirmed stable reciprocal requirements between different binaries and rejection of wrong identities/ad-hoc replacements. No privacy permissions were reset.

Final 0.10.1 DMG SHA-256: `a6493a24d0823b4e868ece2802c72fbf9cd97d479369a412789e182bcb234a6f`. The UI review resolved a cached-connection issue: USB/Bluetooth metadata refreshes on activation and every five seconds while active and unpaused, including when disconnected. Physical connection transitions remain to be checked.
