/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota_auth.h"
#include "sha256.h"
#include <string.h>
_Static_assert(sizeof(KG_OTA_AUTH_DOMAIN)-1==KG_OTA_AUTH_DOMAIN_SIZE,"AUTH domain length");
_Static_assert(sizeof(KG_OTA_HELLO_DOMAIN)-1==KG_OTA_HELLO_DOMAIN_SIZE,"HELLO domain length");
static void put(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(8*i));}
static uint32_t le(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static bool equal(const uint8_t *a,const uint8_t *b,size_t n){volatile uint8_t different=0;for(size_t i=0;i<n;i++)different|=a[i]^b[i];return different==0;}
static bool valid_key(const uint8_t key[32]){if(!key)return false;uint8_t nonzero=0,nonff=0;for(unsigned i=0;i<32;i++){nonzero|=key[i];nonff|=(uint8_t)~key[i];}return nonzero&&nonff;}
static void clear(void *p,size_t n){volatile uint8_t *bytes=p;while(n--)*bytes++=0;}
void kg_ota_hmac_sha256(const uint8_t key[32],const void *bytes,size_t length,uint8_t tag[32]){
    uint8_t block[64],inner[32];kg_sha sha;
    for(unsigned i=0;i<64;i++)block[i]=(i<32?key[i]:0)^0x36;
    kg_sha_init(&sha);kg_sha_update(&sha,block,sizeof block);kg_sha_update(&sha,bytes,length);kg_sha_final(&sha,inner);
    for(unsigned i=0;i<64;i++)block[i]=(i<32?key[i]:0)^0x5c;
    kg_sha_init(&sha);kg_sha_update(&sha,block,sizeof block);kg_sha_update(&sha,inner,sizeof inner);kg_sha_final(&sha,tag);
    clear(block,sizeof block);clear(inner,sizeof inner);clear(&sha,sizeof sha);
}
bool kg_ota_auth_encode(const kg_ota_authorization *a,uint8_t payload[KG_OTA_AUTH_PAYLOAD]){
    if(!a||!payload)return false;
    put(payload,a->manifest.target);put(payload+4,a->manifest.address);put(payload+8,a->manifest.length);put(payload+12,a->manifest.build);
    memcpy(payload+16,a->manifest.sha256,32);put(payload+48,a->source_length);memcpy(payload+52,a->source_sha256,32);
    memcpy(payload+84,a->nonce,16);memcpy(payload+100,a->key_id,16);payload[116]=a->replace?1:0;memcpy(payload+117,a->tag,32);return true;
}
bool kg_ota_auth_decode(const uint8_t payload[KG_OTA_AUTH_PAYLOAD],kg_ota_authorization *a){
    if(!payload||!a||payload[116]>1)return false;
    memset(a,0,sizeof *a);a->manifest.target=le(payload);a->manifest.address=le(payload+4);a->manifest.length=le(payload+8);a->manifest.build=le(payload+12);
    memcpy(a->manifest.sha256,payload+16,32);a->source_length=le(payload+48);memcpy(a->source_sha256,payload+52,32);
    memcpy(a->nonce,payload+84,16);memcpy(a->key_id,payload+100,16);a->replace=payload[116]!=0;memcpy(a->tag,payload+117,32);return true;
}
bool kg_ota_auth_valid(const uint8_t key[32],const kg_ota_authorization *a){
    if(!a||!valid_key(key)||a->source_length<8||a->source_length>KG_OTA_APP_MAX)return false;
    uint8_t digest[32],payload[KG_OTA_AUTH_PAYLOAD],message[KG_OTA_AUTH_DOMAIN_SIZE+117];
    kg_ota_sha256(key,32,digest);bool id=equal(digest,a->key_id,16);
    kg_ota_auth_encode(a,payload);memcpy(message,KG_OTA_AUTH_DOMAIN,KG_OTA_AUTH_DOMAIN_SIZE);memcpy(message+KG_OTA_AUTH_DOMAIN_SIZE,payload,117);
    kg_ota_hmac_sha256(key,message,sizeof message,digest);bool tag=equal(digest,a->tag,32);
    clear(digest,sizeof digest);clear(payload,sizeof payload);clear(message,sizeof message);return id&&tag;
}
bool kg_ota_read_device_key(const kg_ota_io *io,uint8_t key[32]){
    if(!key)return false;
    clear(key,32);
    uint8_t slot[KG_OTA_KEY_SLOT_SIZE],digest[32];bool ok=false;
    if(io&&io->read&&io->read(io->context,KG_OTA_KEY_SLOT,slot,sizeof slot)&&
       !memcmp(slot,"KGKY0001",8)&&le(slot+56)==kg_ota_crc32(slot,56)&&le(slot+60)==UINT32_MAX&&valid_key(slot+8)){
        kg_ota_sha256(slot+8,32,digest);ok=equal(digest,slot+40,16);if(ok)memcpy(key,slot+8,32);
    }
    clear(slot,sizeof slot);clear(digest,sizeof digest);return ok;
}
kg_ota_result kg_ota_hello(const kg_ota_io *io,const uint8_t key[32],uint32_t length,uint32_t build,const uint8_t nonce[16],uint8_t payload[KG_OTA_HELLO_SIZE]){
    if(!nonce||!payload)return KG_OTA_BOUNDS;
    memset(payload,0,KG_OTA_HELLO_SIZE);if(!valid_key(key))return KG_OTA_AUTH_ERROR;
    kg_ota_result result=kg_ota_application_sha256(io,length,payload+8);if(result!=KG_OTA_OK)return result;
    put(payload,KG_OTA_TARGET);put(payload+4,length);uint8_t digest[32],message[100];
    kg_ota_sha256(key,32,digest);memcpy(payload+40,digest,16);put(payload+56,KG_OTA_CAPABILITIES);put(payload+60,build);
    memcpy(message,KG_OTA_HELLO_DOMAIN,KG_OTA_HELLO_DOMAIN_SIZE);memcpy(message+20,nonce,16);memcpy(message+36,payload,64);
    kg_ota_hmac_sha256(key,message,sizeof message,payload+64);clear(digest,sizeof digest);clear(message,sizeof message);return KG_OTA_OK;
}
