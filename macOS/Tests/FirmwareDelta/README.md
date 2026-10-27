# Offline firmware delta planner tests

Run on macOS with Xcode Command Line Tools:

```sh
sh macOS/Tests/FirmwareDelta/run.sh
```

The tests create deterministic synthetic images and never connect to a device,
read user profiles, modify flash, use a network service or access Keychain.

`FirmwareDeltaPlan.make(oldAppData:newAppData:verifiedOldSHA256:target:)`
requires the pinned Q6 Max ISO target and application vectors relocated to
`0x08008000`. Images are limited to 96 KiB. `verifiedOldSHA256` must describe an
independently verified installed image; hashing a local file and assuming that
file is installed does not meet that contract. Missing, invalid or mismatching
baseline evidence produces a literal plan with an explicit `baselineUse` reason.

Every plan is independently reconstructed and SHA-256 checked. A COPY requires
exact matching bytes within the verified baseline, including at unaligned source
offsets. The plan retains 256-byte target chunks and coalesces contiguous COPY
runs up to the 96 KiB image limit, including a final short image tail when present. Wire
encoding, device identity/authorization, acknowledgements, baseline negotiation,
resumption and hardware installation are outside this pure planner.

`budget` counts fresh HELLO, pre-authorization STATUS, AUTH_BEGIN, resume STATUS, data/COPY, FINISH, COMMIT
and post-reboot HELLO. It includes compact KGAK replies, a 19-byte ACK_ACK receipt
after every reply, and separate baseline/restoration writes for each outgoing
frame. The initial review-only HELLO is outside the installation budget. Additional
reconnection reads can be supplied by the caller. Its explicit retry fraction is rounded
up to whole repeated exchanges, each budgeted at the largest request/reply size.
RF bytes remain unknown unless link overhead assumptions are supplied. Timing
requires measured write/report ranges; no completion scenario is produced while
the aggregate pause allowance remains unknown. An estimate is never evidence
that the proposed Bluetooth OTA path works on hardware.
