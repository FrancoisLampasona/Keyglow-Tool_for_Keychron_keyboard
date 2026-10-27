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

Maximum frame:276 bytes. Bad lengths, CRC, version, operation or payload shape
produce no writes/reply. `ble/` contains the experimental LED/reserved-byte
transport; see its contract for framing, compact replies and receipt handling.
The relocated QMK integration binds it separately from the RGB parser. Short
hardware nonce/CRC exchanges and a separate verified USB bootstrap of loader/build
8 have been observed on one unit. Neither establishes a complete Bluetooth A→B
update or physical interruption recovery.

| Operation | Payload |
|---|---|
| 1 BEGIN | Manifest (48 bytes), then `replace` byte 0 or 1 |
| 2 DATA | Image offset u32 followed by 1..256 bytes |
| 3 STATUS | Empty |
| 4 FINISH | Empty |
| 5 COMMIT | Empty |
| 6 COPY | Destination offset u32, source offset u32, length u32 |
| 7 AUTH_BEGIN | Authenticated owner envelope,149 bytes; described below |
| 8 HELLO | Fresh host nonce,16 bytes; handled by the application adapter |

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

COPY is28 bytes including framing. Source offsets are relative to application
base, never arbitrary flash addresses. The source must remain within the96KiB
application region. The host additionally restricts it to the verified baseline
length. Destination is256-byte aligned; length covers complete target chunks,
except the final image tail, and is1..98304 bytes. Consecutive source/destination
runs may be coalesced. The QMK adapter performs one256-byte chunk per foreground
poll, checking idle/power/authentication between chunks, with a60-second total
request deadline. Each chunk reuses DATA readback/bitmap rules. Lost volatile
cursors can be retried from the original offsets without rewriting completed
identical chunks. A wrong baseline can never pass the final target SHA256.

The legacy portable entry point supports unsigned BEGIN for tests only. The
secure application entry rejects operation1, requires a valid owner keyslot and
AUTH_BEGIN, and authenticates the persisted session before every mutation.
Optional application policy can restrict this further but cannot bypass HMAC.

## Owner authorization and HELLO

AUTH_BEGIN payload offsets:

| Offset | Size | Meaning |
|---|---:|---|
|0|48|Target manifest in the layout above|
|48|4|Current source application length,8..98304|
|52|32|SHA256 of those current application bytes at APP_BASE|
|84|16|Host-generated transaction nonce|
|100|16|Key identifier: first16 bytes of SHA256(owner key32)|
|116|1|Replace flag, exactly0 or1|
|117|32|HMAC-SHA256(owner key, domain + payload bytes0..116)|

Domain is the19 ASCII bytes `KEYGLOW-OTA-AUTH-V2`, without NUL. Total request is
165 bytes. HMAC binds the exact target, old source, nonce, key ID and replace flag.
BEGIN validates the source digest before staging erase. Literal-only updates
still bind current source identity; they simply do not require a cached baseline.
Source is a byte region and need not contain application vectors, which permits
the initial standard-layout QMK text to authorize bootstrap relocation.

HELLO is read-only and works without staging. Its compact successful reply
payload is96 bytes, also available at offsets20..115 of the full engine reply:

|Offset|Size|Meaning|
|---|---:|---|
|0|4|Target|
|4|4|Current application length from linker load-image end|
|8|32|Current application SHA256, freshly read|
|40|16|Owner key ID|
|56|4|Capabilities: bit0 owner HMACv2, bit1 COPY, bit2 persistent resume|
|60|4|Compiled `KEYGLOW_OTA_BUILD`, independent of staging metadata|
|64|32|HMAC-SHA256 over domain + request nonce16 + reply bytes0..63|

HELLO domain is20 ASCII bytes `KEYGLOW-OTA-HELLO-V1`, no NUL. The host uses key ID
only to select a Keychain item, then verifies the HMAC and pending nonce before
trusting current identity. No owner key is transmitted. The host displays and
approves the target before producing AUTH_BEGIN. Post-install HELLO must match
the complete target digest, length and intended compiled build.

This authenticates the owner, not a publisher. It is not secure boot or a
monotonic anti-rollback scheme. Source binding rejects old authorization against
a different current image; returning to the same source could allow replay.
A random nonce alone does not prevent replay across reboot. Physical DFU/SWD or
compromised running firmware can extract the device key: readout protection is
deliberately unchanged.

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
There is no streaming fire-and-forget commit. The experimental reserved-byte
transport requires an ACK_ACK matching request ID, operation and reply CRC
before it calls delivered. Successful COMMIT then waits 1500ms before
reset so the host can restore LED state. Reply expiry is60 seconds. Cancellation
drops volatile work/replies, retaining durable chunks and any committed image;
it cannot revoke a completed commit or an already acknowledged reset.

Core result11 is authentication failure;12 is source identity mismatch. Core
results0..10 retain their existing values. Compact replies map adapter
0x100/0x101/0x102 to0x80/0x81/0x82 explicitly; unknown results are rejected.

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

Format1 above remains only for legacy simulation compatibility. The secure
loader rejects it even if every checksum/digest is valid. Format2 uses the same
256-byte header with these changes:

|Offset|Size|Meaning|
|---|---:|---|
|0|8|ASCII `KGOTA002`|
|8|4|Format2|
|64|4|CRC32 of concatenation: bytes0..63,88..123,176..240|
|84|4|Install-start checkpoint, erased or0xFFFFFFFE|
|88|4|Approved source length|
|92|32|Approved source SHA256|
|124|4|Reserved, erased|
|176|16|Nonce|
|192|16|Key ID|
|208|32|HMAC tag|
|240|1|Replace flag|
|241|15|Reserved, erased|

Seal at68 is written after every immutable authentication byte. Loader verifies
HMAC, all target bytes/digest/vectors and source identity, then persists the
install-start marker before the first application erase. Once marked, reboot
rechecks HMAC and staged target but does not require a partially erased source
to hash to the old image. This checkpoint is a trusted flash-driver invariant,
not a replacement for physical tamper resistance. Installed implies started.

## Private owner slot and first installation

Sector0's final256 bytes are excluded from loader linking. At0x08003F00 a64-byte
private slot contains: magic `KGKY0001`(8), key32, keyID16, CRC32 LE over the first
56 bytes, then4 erased bytes. Invalid magic/CRC/ID or all-zero/all-FF key denies
access. OTA never writes the loader, owner slot or EEPROM. No key is generated
by the firmware. Private personalized loader binaries must never be published or
bundled with the app.

Default integration builds produce an unprovisioned loader and no bootstrap
phases. `integration/provision.py` takes an existing0600 keyslot, verified full
read-back and matching standard-layout firmware, then creates authenticated
staging and personalized loader only in a new0700 private directory, all files
0600. It does not flash. Initial sector0 replacement is not atomic; application
Esc recovery is not proof of independent BOOT0/SWD recovery.

## Offline package

`.kgfw`: ASCII `KGFW0001` (8 bytes), manifest (48 bytes), CRC32 of preceding 56
bytes (4 bytes), followed by exactly `manifest.length` image bytes. Total header
60 bytes. A package is an exchange format, not a raw flash image. The loader never
writes the package header into application flash.
