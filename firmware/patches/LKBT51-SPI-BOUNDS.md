# LKBT51 SPI transfer bounds

The pinned Keychron QMK revision `2b493ff95f2665db719b1e95c91babb5036e72f3`
sets `expect_len` to 64 after sending a command. `lkbt51_read` adds four command
bytes, then requests a 68-byte synchronous SPI exchange. Its transmit allocation
and the caller's receive allocation are each only 64 bytes. A host regression
using the actual upstream function reproduces both the out-of-bounds read and
write under AddressSanitizer.

`lkbt51-spi-bounds.patch` grows only those two allocations to 68 bytes and rejects
read lengths above `PACKET_MAX_LEN` before accessing SPI. It preserves the four
command bytes, the 64-byte requested read, all 68 SPI transfer bytes and the
existing `BUFFER_SIZE == 64` parser limit. This is not a packet-format change.
The patch does not otherwise alter the upstream packet parser or queue policy.

`firmware/apply-qmk-patch.py` includes the same transformation, verifies the QMK
revision, validates edits before writing, and is idempotent. Its `--check` mode
does not modify the checkout. Existing firmware binaries do not gain the fix
until a newly built image is explicitly installed.

Run the offline regression from the project root:

```sh
python3 firmware/tests/test_lkbt51_spi_bounds.py
```

The test reads committed upstream source with `git show`, patches it in memory,
checks the public diff matches the integrated transformation, requires both
upstream ASan failures, and validates all `uint8_t` lengths against a synchronous
SPI stub after the fix. It never patches the QMK checkout, compiles a keyboard
image, opens a device or flashes firmware.

This establishes a memory-safety defect. It does not establish that the defect
caused any particular Bluetooth input report or update interruption. Hardware
qualification of an image containing the fix remains separate.
