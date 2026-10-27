# Q6 Max Bluetooth return-channel probe

This is a diagnostic candidate, **not a Bluetooth firmware updater**. It tests whether the Q6 Max LKBT51 radio and macOS preserve the reserved byte of an otherwise empty keyboard input report. That behavior is **unverified on hardware**. A submitted radio report, USB counter or successful compilation does not prove delivery to the Mac.

The build copies the working `tastiera_bt` keymap and unchanged RGB decoder, RGB bridge and responsive-idle sources. The keymap additions observe the diagnostic chord and LED output, then run a bounded diagnostic in the housekeeping hook. Normal key processing, RGB persistence, VIA and energy policy remain in place. No loader, relocated application, staging slot or flash-update operation is added. Build scripts do not flash anything or replace `dist/firmware`.

## Deliberate one-shot trial

After installing this exact diagnostic through the separately reviewed installation procedure:

1. Use Bluetooth, with the USB cable disconnected, and open the dedicated Mac probe receiver. The receiver must be ready before the following sequence.
2. Hold the physical Fn key first. Then hold ○ above Num for at least two seconds, and release both within five seconds. Hold no other key. This opens a 30-second diagnostic window; it does not send any keyboard report by itself.
3. Within that window, the Mac sends one fresh four-byte nonce in a `KPRB` LED challenge. The sender restores the original LED mask after sending. Do not type, use the encoder, or switch transport during the trial.
4. A valid challenge produces one `KPAK` response after at least 600 ms of settling, followed by a zero reserved-byte report. The response takes approximately 2.6 seconds. The whole LED request/response trial takes about seven seconds with 80 ms LED symbols.
5. The Mac accepts success only after receiving the entire response with the expected nonce, alternating markers, zero modifiers/keycodes, version, status and CRC. If no valid response arrives, the radio or macOS may have dropped/rewritten the reserved byte; that is an unresolved channel, not success.

Any key press cancels the waiting/sending state; the core also checks all physical matrix positions, normal/NKRO report state, real/weak/one-shot/locked modifiers, consumer/system usages, wireless report queue/retries, transport/connection and critical battery. A transient key event cancels even when the key is already released by the next scan. A reconnect hook cancels disconnect/reconnect pairs occurring in one housekeeping pass. Cancellation never enqueues a later cleanup report that could release a real key. Another deliberate chord is required for another trial.

## Wire format

Both packets contain 13 bytes. CRC is CRC-16/CCITT-FALSE, polynomial `0x1021`, initial `0xffff`, over bytes 0–10; the two CRC bytes are big endian.

| Offset | Host request | Keyboard response |
|---|---|---|
| 0–3 | `4B 50 52 42` (`KPRB`) | `4B 50 41 4B` (`KPAK`) |
| 4 | `01` version | `01` version |
| 5 | `01` challenge | `00` accepted |
| 6–9 | Fresh opaque nonce | Exact nonce echo |
| 10 | `00` reserved | `00` reserved |
| 11–12 | CRC big endian | CRC big endian |

Host → keyboard uses the existing LED transport: two bits per symbol in Num/Caps, Scroll bit as alternating clock, most significant two bits first, about 80 ms per symbol. Start by establishing clock low, preserve unrelated LED bits, and restore original indicators afterward. The diagnostic parser recognizes only `KPRB`; it does not interpret a challenge as an RGB command. Only a valid challenge inside the physically armed window can prepare a response.

Keyboard → host emits 26 reports through the existing `lkbt51_send_keyboard` command `0x11`. Every report is eight bytes:

```
00 RR 00 00 00 00 00 00
```

Only `RR`, the reserved byte, changes. Packet bytes are split into high nibble then low nibble. Even symbol indices use `RR = 0x80 | nibble`; odd indices use `0x90 | nibble`. This guarantees adjacent reports differ, including repeated/zero nonce nibbles. The interval is 100 ms. A 27th all-zero report ends the one-shot sequence. No modifier, keycode, consumer usage or system event is synthesized.

## Read-only counters over USB

Without turning the keyboard off, reconnect USB and select Cable after a trial. Send a 32-byte VIA custom-get request `08 4B 50 00 … 00`. The response keeps bytes 0–2 and returns:

| Bytes | Meaning |
|---|---|
| 3 | Diagnostic schema `01` |
| 4 | State: 0 idle, 1 holding, 2 waiting release, 3 waiting challenge, 4 settling, 5 sending, 6 done, 7 aborted |
| 5 | Last abort: 0 none, 1 key, 2 link, 3 logical report, 4 queue, 5 timeout, 6 short chord, 7 battery |
| 6 | Response symbols submitted, 0–26 |
| 7 | Zero |
| 8–11 | Arm attempts, uint32 big endian |
| 12–15 | Valid challenges |
| 16–19 | Calls submitted to the radio keyboard-report path, including final zero |
| 20–23 | Sequences completed locally |
| 24–27 | Aborts |
| 28–31 | Invalid complete challenge frames |

Counters live in RAM and reset on power loss. USB switching aborts an active trial but preserves counters. This request cannot arm, reset, save, update or flash anything. Other custom commands remain unhandled. Counters describe local execution, **not radio acknowledgements or host receipt**. They contain no typed keys or nonce.

## Build and verify

```
sh firmware/diagnostics/test.sh
sh firmware/diagnostics/build-probe.sh
```

Tests compile the production core and QMK adapter with ASan/UBSan and stub every hardware sink. They cover packet validation/CRC, exact nonce echo and safe report bytes, all matrix positions, every normal/NKRO key slot, modifier types, queue retries, critical battery, timing/rollover, transient events, transport changes and one-shot behavior.

The build is pinned to Keychron QMK `2b493ff95f2665db719b1e95c91babb5036e72f3` plus the existing working RGB/idle integration. It uses the standard Q6 Max ISO layout, a separate `keyglow_probe` keymap and `build/bt-probe/qmk-output`. Output binary/ELF, section map, size, log and SHA256 are under `build/bt-probe` only.

Static evidence: the pinned `keyboards/keychron/common/wireless/lkbt51.c` copies all eight bytes into command `0x11`; `tmk_core/protocol/report.h` labels byte 1 reserved. This proves the MCU submission format only. The radio's HID descriptor/forwarding and macOS delivery still need the live nonce trial.
