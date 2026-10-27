# Keyglow Bluetooth OTA framing

This directory binds the authenticated OTA engine to the existing Q6 Max ISO
LKBT51 HID paths. It does not update the radio, flash USB firmware, provision an
owner key, or replace the loader. Integration and bootstrapping belong to
`../integration` and `../stm32f401`.

## Evidence and limits

The separate KPRB/KPAK diagnostic passed physical nonce-and-CRC round trips with
the USB cable disconnected at LED symbol intervals of 80, 40 and 20 ms. Each was
a single short challenge, with response reports at 100 ms. These measurements
do **not** establish reliable bulk firmware delivery, return intervals below
100 ms, or successful OTA installation. The authenticated loader and relocated
build 8 subsequently booted after a verified USB bootstrap on one unit. A complete
Bluetooth A→B transfer and authenticated post-install identity are still awaiting
hardware verification.

`keyglow_ble_wire.c` and `BluetoothOTAWire.swift` share synthetic fixtures in
`vectors.json`. `make-vectors.py` independently computes them with Python's CRC32
and a CCITT implementation. Fixture authentication bytes are deliberately
synthetic and are not valid signatures or device credentials.

## Frames

All multibyte fields are little endian unless explicitly marked BE.

| Frame | Layout | Maximum |
| --- | --- | --- |
| Request | `KGOT`, version1, operation1, payloadLength2, requestID4, payload, CRC32-IEEE4 | 276 bytes |
| Reply | `KGAK`, version1, echoedOperation1, requestID4, result1, flags1, payloadLength1, payload, CRC16-CCITT-BE2 | 143 bytes |
| Receipt | KGOT operation `0x7F`, matching requestID, payload `[echoedOperation, replyCRC_hi, replyCRC_lo]`, outer CRC32 | 19 bytes |

The CRC16 initial value is `0xFFFF`, polynomial `0x1021`. CRC32 uses the standard
reflected IEEE polynomial, initial/final XOR `0xFFFFFFFF`.

Requests have at most 260 payload bytes. COPY operation6 carries destination
offset, source offset and length (three UInt32 values); the engine bounds its
length to 98,304 bytes and executes one durable 256-byte chunk per poll.
AUTH_BEGIN operation7 has 149 opaque payload bytes and is verified by the engine,
not the wire codec. HELLO operation8 and STATUS operation3 return the engine's
96-byte state area. Other compact replies have no extra payload. Core result
values 0–12 are unchanged; adapter results `0x100`, `0x101`, `0x102` map explicitly
to `0x80`, `0x81`, `0x82`. Unknown results and flags above the low four bits fail
validation. A matching CRC proves integrity, not authorization or delivery.

Requests travel as two data bits (Num/Caps) and an alternating Scroll clock. The
first mask establishes clock low. Hosts must preserve Compose/Kana and restore
the original mask even on cancellation or failed writes. A 400 ms intersymbol
gap cancels an incomplete frame; the complete-frame ceiling is 180 seconds.
The decoder searches for magic only outside a frame, so firmware payloads may
contain literal `KGOT`, `KRGB`, or any other byte sequence.

Replies use eight-byte keyboard reports `[0, reserved, 0, 0, 0, 0, 0, 0]`.
Each byte produces high and low nibble reports with marker `0x80` then `0x90`.
A final all-zero report ends the transmission. No data becomes a modifier,
keycode, consumer usage or system usage. The active QMK glue fixes reply pacing
at 100 ms. Pure codecs represent explicitly calibrated 40/20 ms return rates,
but nothing enables them based on downlink tests.

## QMK integration

Compile the four `keyglow_ble_wire.[ch]` and `qmk_ble_ota.[ch]` files into the
isolated keymap. The integration preparer owns the hook wiring:

1. Call `keyglow_ble_ota_process_record(record)` before normal key/RGB handling.
2. Call `keyglow_ble_ota_led_update(state)` before the RGB LED decoder. Forward
   to the RGB decoder only when this returns true.
3. Call `keyglow_ble_ota_task()`, then `keyglow_ota_task()`, then the ordinary RGB
   matrix task. These hooks run in the foreground, never an interrupt.
4. Include `!keyglow_ble_ota_busy()` in the existing low-power veto. The glue
   defines the previously empty `wireless_enter_connected_kb` callback to abort
   a disconnect/reconnect pair even within one housekeeping pass.

No Fn chord is required: authenticated engine policy gates mutations. Input and
output require Bluetooth connected, all physical keys up, no strong/weak/one-shot
or locked modifiers, no 6KRO/NKRO keys, no consumer/system usage and no critical
battery condition. Reports start after 600 ms of idle radio queue time. A busy
queue during transmission aborts; settling has a five-second bound. No report
is enqueued for delayed emission after typing resumes.

KGOT frames suppress the RGB decoder while collecting or pending, so valid RGB
bytes inside firmware cannot change lighting. Conversely, an outer KRGB frame
owns its entire payload and CRC: HSV/speed bytes may literally spell KGOT
without being mistaken for an update. A second, side-effect-free RGB decoder
only identifies that outer frame; it never applies colors or arms the real RGB
listener. Invalid frames and interrupted
transactions discard following LED traffic until 400 ms of silence. Normal RGB
handling resumes after that gap. Neither a key interrupt nor a disconnect emits
an all-zero report over live typing.

Only one engine operation is outstanding. A cached reply can be replayed for a
byte-identical request, at most twice within its original 60-second lifetime,
without repeating the mutation. The LED decoder stays active while replying,
including for a receipt that starts before the final zero report. The receipt
is accepted only after that zero has actually been submitted to LKBT51, and
only when its request ID, operation and reply CRC match. There is no reply to a
receipt. The adapter delays a successful COMMIT reset by 1500 ms after
receipt delivery, allowing the host to restore the LED mask.

The 60-second reply bound also bounds cached retries. Repeating a maximum-size
request at 80 ms per LED symbol can exceed it. After an ambiguous long transfer,
the host must wait out the old transaction and recover using STATUS and the
durable chunk bitmap; it must not assume a long retry was delivered. A missing
reply or failed receipt never means success. Cancellation drops queued/COPY
work and unacknowledged replies without erasing staging. A COMMIT already made
durable can still be installed on a later physical restart even if its reply
was lost; STATUS and subsequent boot identity must resolve that outcome.

## Checks

From the repository root:

```sh
sh firmware/ota/ble/test.sh
sh macOS/Tests/BluetoothOTA/run.sh
```

The C suite uses ASan/UBSan, stub HID/engine sinks and no flash API. It checks
CRC corruption, truncation, reordered/dropped clock edges, duplicate LED
notifications, bounds, wrapped timers, embedded protocol magic, mailbox
backpressure, all physical/logical key guards, cached retries, receipts,
disconnects and abort quarantine. Swift tests consume the same fixtures and
exercise in-place report filtering (including throughout the final receipt),
strict nibble markers, malformed lengths,
deadlines, request identity, receipts and production RGB mask rejection.
