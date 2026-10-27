# Keyglow HID Probe

Standalone, deliberately gated diagnostic for the `keyglow_probe` firmware. It does not implement or start an OTA update. Building it never launches it or accesses hardware.

```
sh macOS/Tests/Probe/run.sh
sh scripts/build-bt-probe.sh
```

The signed development bundle is `build/Keyglow HID Probe.app`, identifier `local.keyglow.hid-probe`. At launch it checks Input Monitoring and requests it once if needed. If access remains denied, it opens the relevant Privacy page. Returning from Settings only refreshes the status. A rebuild can change the ad hoc signature, so finish building before granting access.

Builds are compiled and signed in a staging directory. Publishing uses an atomic directory exchange and retains the previous signed bundle in that staging directory. If the app is running or process inspection is unavailable, the candidate is left staged. After independently confirming that the old app is closed, `sh scripts/build-bt-probe.sh --replace-closed` publishes the new build.

The Bluetooth challenge starts only after the user confirms installation of the diagnostic firmware and the physical Fn + ○ hold/release, then presses **Avvia prova Bluetooth**. It requires exactly one matching Bluetooth Q6 Max ISO (`3434:0861`, primary usage `1/6`), validates the existing LED descriptor, and opens the device non-exclusively. Production `RGBProtocol.validMasks` and HID helpers are unchanged.

Input callbacks exist only for the bounded trial, at most 15 seconds. Input report 1 accepts eight payload bytes, optionally preceded by ID 1; NKRO report 4 accepts twenty payload bytes, optionally preceded by ID 4. Any nonzero modifier/key field aborts immediately without copying those fields. Only reserved-byte diagnostic nibbles from otherwise empty report 1 enter the nonce/CRC parser. The receive buffer is cleared after each callback and on teardown. No raw input or typed keycodes are logged or saved.

The KPRB challenge uses the firmware's fixed 13-byte format, a fresh four-byte nonce and CRC-16/CCITT-FALSE. The default remains an 80 ms pause after each completed LED write. The user may explicitly select 40 or 20 ms for one physically armed trial. The runner rejects nonfinite pauses and values outside 20–80 ms before opening a device; it never pipelines requests. Actual spacing also includes the IOKit write duration. Indicators preserve Compose/Kana and restore the exact original mask even after a failed first write. Output/snapshot operations use the asynchronous IOKit API with 500 ms device timeouts. The return parser requires 26 alternating `0x8n`/`0x9n` symbols, KPAK framing, matching nonce and CRC. A successful IOKit write alone never counts as success.

Speed trials need no firmware change. The installed probe has no minimum challenge-symbol interval, but its 400 ms maximum gap and the radio/QMK LED-event processing can still cause losses. In particular, queued LED events may be collapsed to the latest state before `led_task()` runs. The 40/20 ms choices therefore remain experimental until independently verified with a fresh nonce and valid CRC. The firmware's response timing stays at 100 ms per nibble and a 600 ms settling delay; these limits cannot be accelerated by this host setting.

**Leggi contatori USB** runs a separate background, read-only VIA session. It requires one ISO keyboard, protocol 12 and exact firmware build `v1.1.1 2026-10-26-23:17:58`, then queries `08 4B 50`. It does not read keymaps, macros or switch-matrix data. Reconnect USB and choose Cable without powering off the keyboard to preserve the firmware's RAM counters. Counters prove local execution, not Bluetooth delivery.

The result directory is configured in the generated Info.plist key `KeyglowProbeResultPath`; override its full file path with `KEYGLOW_PROBE_RESULT_PATH` during build if needed. By default results are private files under `research/bluetooth-v08/probe/private/`:

- `host-result.json`: status, counts, nonce/CRC verification booleans, restoration result, elapsed milliseconds, and bounded IOKit failure stages/codes. Timing fields record the requested post-write pause, first/final challenge-write times relative to trial start, mean/maximum challenge-write duration, first/last valid response-symbol times and roundtrip from first write to complete reply. Failed attempts include available partial metrics. No raw nonce or input reports.
- `usb-counters.json`: verified-build flag, firmware state and integer counters.

Files are created with permissions `0600`; symlink targets are refused. Tests use fake HID/VIA channels only, including failed writes/restoration, deadline/disconnection/cancellation, typing aborts, malformed reports, nonce/CRC failures, strict USB build checks and private result serialization.
