# Owner authorization tests

```sh
sh macOS/Tests/FirmwareAuthorization/run.sh
```

This suite uses a deliberately public synthetic key, independently calculated
Python `hashlib`/`hmac`/`zlib` vectors, and an in-memory key store. It does not
generate random keys, instantiate the Keychain store or touch a keyboard.

## Contract

`FirmwareAuthorization.makePayload` produces operation 7's 149-byte payload:
48-byte manifest, source length (LE32), source SHA-256 (32 bytes), transaction
nonce (16 bytes), key ID (16 bytes), replace flag (one byte), HMAC-SHA256 (32
bytes). The HMAC authenticates the 19 ASCII bytes `KEYGLOW-OTA-AUTH-V2`, without
a NUL terminator, followed by the first 117 payload bytes. The key ID is the
first 16 bytes of SHA-256 over the 32-byte owner key.

The manifest pins Q6 Max ISO target `0x08613434`, application base `0x08008000`,
and length 8..98304. The source length and SHA must match the separately reported
current controller identity, including for literal-only updates. Target image
bytes, relocated vectors and the final full SHA-256 remain separate checks.
`verifyPayload` also checks the expected pending transaction nonce.

`bootstrapKeySlot` creates the 64-byte slot for `0x08003F00`: `KGKY0001`, key,
key ID, little-endian CRC32 over the first 56 bytes, and four erased `FF` bytes.
The parser requires this exact format, matching ID and CRC, and rejects empty,
all-zero and all-FF keys. The slot contains a secret: real slots must stay out of
logs, profiles, diagnostics, source control and published firmware packages.

## Storage and security boundaries

`FirmwareOwnerKeyStoring` exposes scoped lookup and add-only storage.
`KeychainFirmwareOwnerKeyStore` uses one dedicated generic-password service,
key ID accounts, no synchronization, and device-only accessibility while
unlocked. A locked or denied lookup returns an error without prompting from a
background call. Its initializer has no side effects. Platform access policies
still depend on the app's signing identity and the user's Keychain settings.

Generate an owner key only by explicitly calling
`generateForUserApprovedBootstrap` during user-approved provisioning. Generate a
transaction nonce only when beginning an update. Neither action runs at startup.
Descriptions and reflection of `FirmwareOwnerKey` redact key material; Swift
managed-memory copies are not guaranteed to be zeroized immediately.

HMAC proves possession of the shared owner key, not publisher identity. A nonce
provides transaction correlation, not a standalone replay defense. Binding the
source hash rejects replay against a different installed image, but there is no
monotonic version policy or anti-rollback guarantee. Anyone obtaining the owner
key can authorize images; compromise of the host or physical provisioning
material is outside this format's protection.
