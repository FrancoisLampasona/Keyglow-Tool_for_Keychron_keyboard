/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include "keyglow_ota_wire.h"

/* Transport-neutral API. Complete CRC-checked frames only, not HID fragments.
 * No Bluetooth/USB/keyboard report path is bound by this integration. */
bool keyglow_ota_submit_frame(const uint8_t *frame,size_t size);
bool keyglow_ota_peek_reply(uint8_t *out,size_t capacity,size_t *size);
bool keyglow_ota_reply_delivered(uint32_t request_id);
bool keyglow_ota_busy(void);
/* Drops volatile work/reply after typing/disconnect. Durable chunks and commit
 * remain. Cannot retract processing or an already acknowledged reset. */
bool keyglow_ota_cancel_pending(void);
typedef bool (*keyglow_ota_authorizer)(const kg_ota_manifest *manifest);
bool keyglow_ota_set_authorizer(keyglow_ota_authorizer verifier);
void keyglow_ota_task(void);
void keyglow_ota_note_key(void);

/* Optional extra trusted policy. Absent callback permits policy, but every
 * mutation still requires a valid owner key slot and matching HMAC. A callback
 * cannot bypass that authentication. This hook never verifies radio delivery. */
bool keyglow_ota_manifest_authorized(const kg_ota_manifest *manifest);

/* Transport/session rejection codes in otherwise ordinary KGOT replies. */
enum { KEYGLOW_OTA_UNAUTHORIZED=0x100, KEYGLOW_OTA_POWER=0x101,
       KEYGLOW_OTA_BUSY_TIMEOUT=0x102 };
