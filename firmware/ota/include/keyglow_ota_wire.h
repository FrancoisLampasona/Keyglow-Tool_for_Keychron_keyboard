/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGLOW_OTA_WIRE_H
#define KEYGLOW_OTA_WIRE_H
#include "keyglow_ota.h"
#define KG_OTA_FRAME_MAX 276u
#define KG_OTA_REPLY_SIZE 120u
enum { KG_OTA_BEGIN=1, KG_OTA_DATA=2, KG_OTA_STATUS=3, KG_OTA_FINISH=4, KG_OTA_COMMIT=5 };
/* Complete, reassembled frames only. Invalid frames produce no writes/reply.
 * Serialized caller, not interrupt context. A valid COMMIT reply must be sent
 * before a future transport adapter resets into the loader. No reset here. */
bool kg_ota_handle_frame(const kg_ota_io *,const uint8_t *,size_t,uint8_t *,size_t,size_t *);
#endif
