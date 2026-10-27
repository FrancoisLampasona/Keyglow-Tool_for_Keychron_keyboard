# Firmware workflow tests

```sh
sh macOS/Tests/FirmwareUpdate/run.sh
```

The coordinator's transport, key lookup, baseline cache, nonce and waiting are
injected. Tests use synthetic images, a public test key and an in-memory device.
The live Bluetooth I/O implementation is compiled but never constructed or used.
The UI-model lifetime tests inject review/provisioning operations; they do not
generate keys, access Keychain, create files or open a panel.

The suite covers package CRC/SHA/target validation, raw-image build requirements,
authenticated HELLO and source identity changes, delta/literal fallback, read-only
review with HELLO and STATUS, a fresh identity check before mutation,
pre-authorization STATUS, AUTH_BEGIN and matching STATUS, missing-chunk
resume, coalescing across only contiguous missing COPY chunks, cancellation,
typing, malformed replies, lost acknowledgements after mutations, and checking
the installed SHA/length/build after COMMIT. No mutation is automatically retried.
A failed final verification never becomes a successful update.

Review exposes empty, partial and completed staging sessions without AUTH_BEGIN.
Malformed status lengths, flags, bitmap/state combinations and CRC are rejected.
The owner key is loaded once per review/install action and dropped on success,
failure or cancellation; each fresh HELLO is still authenticated, including after
reboot. Tests count key loads and require the Keychain progress phase before any
lookup. These tests never access the real Keychain.

The fake enforces the controller's staging replacement contract. A completed
installed stage is automatically replaced only when its target/address/length/
hash/build match the freshly authenticated running image. An uncommitted stage
requires matching-target resume or explicit user replacement. A committed but
not installed stage can resume its matching target but can never be replaced.
The suite covers bootstrap A → update B, stale installed metadata, pending
commits, explicit replacement and bitmap-preserving resume.

The app retains detached operations through their MainActor completion so leaving
the page cannot orphan its global busy flag. Cancelled or interrupted transport
sessions wait for the 60-second pending-reply expiry before another user-requested
read. Post-COMMIT read retries are bounded and honor that expiry after read errors.

The live setup button is explicit and independent of update verification. It
creates or reuses a private 64-byte owner-key slot with mode 0600 and a dedicated
Keychain entry. Actual Keychain/provisioning, native rendering, and hardware OTA
remain separate integration checks; passing this suite does not prove them.

## Complete-stage resumption

The workflow tests also cover a matching READY stage and a stage that changes
after review. Only a fresh, complete matching stage can skip preparation; its
finalization still uses FINISH, COMMIT and authenticated post-boot identity.
`../FirmwareEngine/run.sh` exercises this path against the real C engine with
RAM flash, including lost DATA/FINISH replies and wrong-key rejection. It does
not access a physical keyboard.
