/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGLOW_OTA_AUTH_H
#define KEYGLOW_OTA_AUTH_H
#include "keyglow_ota.h"
#define KG_OTA_AUTH_PAYLOAD 149u
#define KG_OTA_KEY_SLOT UINT32_C(0x08003f00)
#define KG_OTA_KEY_SLOT_SIZE 64u
#define KG_OTA_AUTH_DOMAIN "KEYGLOW-OTA-AUTH-V2"
#define KG_OTA_AUTH_DOMAIN_SIZE 19u
#define KG_OTA_HELLO_SIZE 96u
#define KG_OTA_HELLO_DOMAIN "KEYGLOW-OTA-HELLO-V1"
#define KG_OTA_HELLO_DOMAIN_SIZE 20u
#define KG_OTA_CAPABILITIES 7u /* owner HMACv2, COPY, persistent resume */
typedef struct {
    kg_ota_manifest manifest;
    uint32_t source_length;
    uint8_t source_sha256[32],nonce[16],key_id[16],tag[32];
    bool replace;
} kg_ota_authorization;
/* Owner authorization, not publisher identity, anti-rollback or physical
 * tamper resistance. No key generation, provisioning, or persistence here. */
void kg_ota_hmac_sha256(const uint8_t key[32],const void *,size_t,uint8_t tag[32]);
bool kg_ota_auth_encode(const kg_ota_authorization *,uint8_t payload[KG_OTA_AUTH_PAYLOAD]);
bool kg_ota_auth_decode(const uint8_t payload[KG_OTA_AUTH_PAYLOAD],kg_ota_authorization *);
bool kg_ota_auth_valid(const uint8_t key[32],const kg_ota_authorization *);
bool kg_ota_read_device_key(const kg_ota_io *,uint8_t key[32]);
kg_ota_result kg_ota_application_sha256(const kg_ota_io *,uint32_t length,uint8_t digest[32]);
kg_ota_result kg_ota_hello(const kg_ota_io *,const uint8_t key[32],uint32_t application_length,
                          uint32_t build,const uint8_t nonce[16],uint8_t payload[KG_OTA_HELLO_SIZE]);
kg_ota_result kg_ota_begin_authenticated(const kg_ota_io *,const uint8_t key[32],const kg_ota_authorization *);
kg_ota_result kg_ota_check_authorization(const kg_ota_io *,const uint8_t key[32]);
kg_ota_result kg_ota_install_authenticated(const kg_ota_io *,const uint8_t key[32]);
#endif
