# Experimental protocol contract

All integers below are little endian. CRC is CRC-32/ISO-HDLC (zlib CRC32).
SHA-256 is over the exact application image bytes, excluding package/header
metadata and final flash-word padding. The caller serializes transactions.

## Complete request frame

| Offset | Size | Meaning |
|---|---:|---|
| 0 | 4 | ASCII `KGOT` |
| 4 | 1 | Version 1 |
| 5 | 1 | Operation |
| 6 | 2 | Payload size, maximum 260 |
| 8 | 4 | Request ID, echoed by the reply |
| 12 | N | Payload |
| 12+N | 4 | CRC32 over all preceding bytes |

Maximum frame: 276 bytes. Frames with bad lengths, CRC, version, operation, or
payload shape cause no flash mutation and produce no reply. A 32-byte HID path
would need reassembly, sequence tracking, bounded timeouts and retransmission in
a transport adapter; none is installed. The existing LED parser does not accept
these frames.

| Operation | Payload |
|---|---|
| 1 BEGIN | Manifest (48 bytes), then `replace` byte 0 or 1 |
| 2 DATA | Image offset u32 followed by 1..256 bytes |
| 3 STATUS | Empty |
| 4 FINISH | Empty |
| 5 COMMIT | Empty |

Manifest: target u32, application address u32, length u32, build u32, digest[32].
DATA offset must be 256-byte aligned, and data must be exactly the expected chunk
length (including the final short chunk). Out-of-order chunks are supported.
Request IDs correlate replies, not authentication. Lost replies are handled by
retry/status using the persisted manifest and bitmap.

BEGIN with `replace=0` resumes an identical manifest without erasing. `replace=1`
explicitly restarts an uncommitted session, even with the same manifest; use this
after a wrong but CRC-valid chunk produces a FINISH digest failure. A committed
pending installation rejects every `replace=1` request without mutation. An
identical already-installed image remains a successful no-op. After a lost reply
to explicit replacement, retry with `replace=0` to resume the new session rather
than repeatedly erasing it.

## Reply

Header layout is identical; operation is request operation OR `0x80`, payload
size is always 104, and total length is 120. Payload:

| Relative offset | Size | Meaning |
|---|---:|---|
| 0 | 4 | Result enum from `keyglow_ota.h` |
| 4 | 4 | Flags: bit0 valid session, bit1 ready, bit2 committed, bit3 installed |
| 8 | 48 | Manifest, or zeros if unavailable |
| 56 | 48 | Bitmap, set bit means chunk missing; ignore bits past image end |

A reply reports success only after the operation and status read complete.
COMMIT does not reset the MCU. A future adapter must deliver its acknowledgement
before requesting a system reset; after reconnect, the host must check installed
identity/version. The host must never infer receipt from a successful OS write.
There is no streaming fire-and-forget commit and no keyboard-input ACK channel.

## Staging metadata

Staging base is `0x08020000`, header 256 bytes, image starts at base+256.

| Offset | Size | Meaning |
|---|---:|---|
| 0 | 8 | ASCII `KGOTA001` |
| 8 | 4 | Format 1 |
| 12 | 4 | Exact target `0x08613434` |
| 16 | 4 | Application base `0x08008000` |
| 20 | 4 | Image length 8..98304 (valid vectors further constrain it) |
| 24 | 4 | Build number |
| 28 | 4 | Chunk size 256 |
| 32 | 32 | SHA-256 |
| 64 | 4 | CRC32 of bytes 0..63 |
| 68 | 4 | Header seal `0xA71A0A7A`, written last |
| 72 | 4 | Ready |
| 76 | 4 | Commit |
| 80 | 4 | Installed |
| 84 | 44 | Reserved, erased |
| 128 | 48 | Missing bitmap, erased to all ones |
| 176 | 80 | Reserved, erased |

State words accept only erased `0xFFFFFFFF` or set `0xFFFFFFFE`. They are not
part of the immutable header CRC. States are ordered: installed implies commit,
commit implies ready. Every relevant transition revalidates data, not just flags.

## Offline package

`.kgfw`: ASCII `KGFW0001` (8 bytes), manifest (48 bytes), CRC32 of preceding 56
bytes (4 bytes), followed by exactly `manifest.length` image bytes. Total header
60 bytes. A package is an exchange format, not a raw flash image. The loader never
writes the package header into application flash.
