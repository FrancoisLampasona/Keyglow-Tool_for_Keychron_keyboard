# Q6 Max Bluetooth GATT observations

This note records a read-only CoreBluetooth inventory on one **Keychron Q6 Max ISO** with radio firmware **0.2.1**. It contains no device address, serial number, possible chip identifier or raw vendor value. It does not establish a working Bluetooth updater.

## Observed services and characteristics

The connection exposed Device Information (`180A`), Battery (`180F`) and vendor service `00010203-0405-0607-0809-0A0B0C0D1912`.

All three vendor characteristics share prefix `00010203-0405-0607-0809-0A0B0C0D`:

| Suffix | Properties | Read length | Known meaning |
| --- | --- | ---: | --- |
| `2B12` | Read, write without response (`0x06`) | 1 byte | UUID and properties match Telink's OTA characteristic template |
| `2B14` | Read (`0x02`) | 14 bytes | Unknown |
| `2B15` | Read, write without response, notify (`0x16`) | 20 bytes | Unknown |

Descriptor discovery found only a client characteristic configuration descriptor (`2902`) on `2B15`. It read zero on the diagnostic connection. No user-description (`2901`) or presentation-format (`2904`) descriptor was exposed. The diagnostic issued reads and discovery operations, with **zero characteristic writes and no notification subscription**.

After a separate controller diagnostic firmware installation and power cycle, four bytes in `2B14` changed and the `2B15` value remained identical. The radio still reported 0.2.1. This does not identify the fields, demonstrate a live request/reply path, or exclude static metadata copied from another processor.

## What the Telink match establishes

The [official Telink BLE SDK handbook](https://doc.telink-semi.cn/doc/en/software/res/sdk/ble/tl_ble_sdk_multi_connection_en/tl_ble_sdk_multi_connection_en/) defines `TELINK_SPP_DATA_OTA` with the exact `…2B12` UUID. Its example uses read plus write-without-response, a stored one-byte value and an OTA write callback. A stored read value is not a firmware-update acknowledgement.

Even the handbook's OTA version query is a write command, not an ordinary characteristic read. No version, start, end or firmware-transfer command was sent. The UUID match identifies a Telink-compatible endpoint; it does not prove the silicon model or Keychron's implementation. There is no established schema for `2B14` or `2B15`.

## Radio OTA and controller OTA are separate

The Q6 Max's QMK controller communicates with its radio through the LKBT51 driver. The [pinned Keychron driver](https://github.com/Keychron/qmk_firmware/blob/2b493ff95f2665db719b1e95c91babb5036e72f3/keyboards/keychron/common/wireless/lkbt51.c) includes Raw HID commands and a radio DFU bridge, but does not define this GATT table or map these characteristics to a controller update callback.

A writable radio service therefore does not establish that it accepts a QMK image, a Keyglow `.kgfw` package, or arbitrary controller data. No such forwarding or end-to-end acknowledgement has been demonstrated. The experimental Keyglow updater instead uses an HID indicator downlink and a reserved-byte HID return path. Its loader and build 8 have booted after USB provisioning on one test unit; a full Bluetooth update remains unverified. This does not establish a GATT firmware tunnel.

The reserved-byte HID probe in this directory tests a different possible return path. Its result must be reported separately; GATT discovery neither validates that probe nor supplies a faster forward transport by itself.

Before implementing a transport adapter, identify the characteristic protocol and prove delivery to the intended processor. Enabling notifications changes the CCC descriptor; it is a write and is not part of this zero-write inventory. Raw vendor reads may contain persistent device identifiers and should remain private.
