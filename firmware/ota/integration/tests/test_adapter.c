/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "quantum.h"
#include "qmk_ota_adapter.h"
#include "qmk_ota_flash.h"
#include "keyglow_ota_auth.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint32_t clock_ms=1000,keys,modifiers,mutations,resets;
static uint16_t voltage=3900;
static bool usb,valid_battery=true,initial_sample,critical;
static uint8_t flash[256*1024],image[513],protected_snapshot[128*1024];
static kg_ota_manifest allowed;
syssts_t chSysGetStatusAndLockX(void){return 0;}
void chSysRestoreStatusX(syssts_t state){(void)state;}
uint32_t timer_read32(void){return clock_ms;}
uint32_t timer_elapsed32(uint32_t last){return clock_ms-last;}
uint8_t get_mods(void){return (uint8_t)modifiers;}
uint8_t get_weak_mods(void){return 0;}
uint32_t matrix_get_row(uint8_t row){assert(row==0);return keys;}
bool readPin(unsigned pin){assert(pin==0);return !usb;}
void NVIC_SystemReset(void){resets++;}
bool battery_has_valid_reading(void){return valid_battery;}
bool battery_power_on_sample(void){return initial_sample;}
bool battery_is_critical_low(void){return critical;}
uint16_t battery_get_voltage(void){return voltage;}
bool keyglow_ota_flash_target_valid(void){return true;}
uint32_t keyglow_ota_application_length(void){return sizeof image;}

static void put(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(8*i));}
static uint32_t le(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static bool read_flash(void *context,uint32_t address,void *out,size_t size){(void)context;assert(address>=KG_OTA_FLASH_BASE&&address<=KG_OTA_FLASH_END&&size<=KG_OTA_FLASH_END-address);memcpy(out,flash+(address-KG_OTA_FLASH_BASE),size);return true;}
static bool program_flash(void *context,uint32_t address,uint32_t word){(void)context;assert(!(address&3u)&&address>=KG_OTA_STAGE_BASE&&address<=KG_OTA_FLASH_END-4);uint8_t b[4];put(b,word);uint8_t *p=flash+(address-KG_OTA_FLASH_BASE);for(unsigned i=0;i<4;i++){assert((p[i]&b[i])==b[i]);p[i]&=b[i];}mutations++;return true;}
static bool erase_flash(void *context,unsigned sector){(void)context;assert(sector==5);memset(flash+128*1024,255,128*1024);mutations++;return true;}
const kg_ota_io *keyglow_ota_staging_io(void){static const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};return &io;}
static bool authorize(const kg_ota_manifest *m){return m->target==allowed.target&&m->address==allowed.address&&m->length==allowed.length&&m->build==allowed.build&&!memcmp(m->sha256,allowed.sha256,32);}

static size_t frame(uint8_t *out,uint8_t operation,uint32_t id,const uint8_t *payload,size_t size){memset(out,0,KG_OTA_FRAME_MAX);memcpy(out,"KGOT",4);out[4]=1;out[5]=operation;out[6]=(uint8_t)size;out[7]=(uint8_t)(size>>8);put(out+8,id);if(size)memcpy(out+12,payload,size);put(out+12+size,kg_ota_crc32(out,12+size));return 16+size;}
static uint32_t reply(uint32_t id){uint8_t out[120];size_t size=0;assert(keyglow_ota_peek_reply(out,sizeof out,&size));assert(size==120&&le(out+8)==id&&le(out+116)==kg_ota_crc32(out,116));return le(out+12);}
static uint32_t transact(uint8_t operation,uint32_t id,const uint8_t *payload,size_t size){uint8_t request[276];size_t n=frame(request,operation,id,payload,size);assert(keyglow_ota_submit_frame(request,n));clock_ms+=501;keyglow_ota_task();return reply(id);}

int main(void){
    memset(flash,255,sizeof flash);memset(image,0x5a,sizeof image);put(image,0x20010000);put(image+4,KG_OTA_APP_BASE+9);
    allowed=(kg_ota_manifest){KG_OTA_TARGET,KG_OTA_APP_BASE,sizeof image,8,{0}};kg_ota_sha256(image,sizeof image,allowed.sha256);
    memcpy(flash+(KG_OTA_APP_BASE-KG_OTA_FLASH_BASE),image,sizeof image);
    uint8_t key[32],digest[32],manifest[149],message[136];for(unsigned i=0;i<32;i++)key[i]=(uint8_t)(i+1);
    kg_ota_authorization authorization={0};authorization.manifest=allowed;authorization.source_length=sizeof image;
    kg_ota_sha256(image,sizeof image,authorization.source_sha256);kg_ota_sha256(key,32,digest);memcpy(authorization.key_id,digest,16);
    kg_ota_auth_encode(&authorization,manifest);memcpy(message,KG_OTA_AUTH_DOMAIN,19);memcpy(message+19,manifest,117);
    kg_ota_hmac_sha256(key,message,sizeof message,authorization.tag);kg_ota_auth_encode(&authorization,manifest);

    assert(transact(KG_OTA_STATUS,1,NULL,0)==KG_OTA_NO_SESSION);
    assert(!keyglow_ota_set_authorizer(authorize));
    assert(!keyglow_ota_reply_delivered(99));assert(keyglow_ota_reply_delivered(1));
    assert(transact(KG_OTA_AUTH_BEGIN,2,manifest,sizeof manifest)==KEYGLOW_OTA_UNAUTHORIZED);
    assert(!mutations);assert(keyglow_ota_reply_delivered(2));
    uint8_t *slot=flash+(KG_OTA_KEY_SLOT-KG_OTA_FLASH_BASE);memcpy(slot,"KGKY0001",8);memcpy(slot+8,key,32);memcpy(slot+40,digest,16);put(slot+56,kg_ota_crc32(slot,56));
    memcpy(protected_snapshot,flash,sizeof protected_snapshot);
    uint8_t nonce[16]={7},hello_reply[120];size_t hello_size;
    keys=1;voltage=3500;
    assert(transact(KG_OTA_HELLO,50,nonce,sizeof nonce)==KG_OTA_OK);
    assert(keyglow_ota_peek_reply(hello_reply,sizeof hello_reply,&hello_size)&&hello_size==120);
    assert(le(hello_reply+20)==KG_OTA_TARGET&&le(hello_reply+24)==sizeof image&&le(hello_reply+76)==KG_OTA_CAPABILITIES&&le(hello_reply+80)==8);
    uint8_t hello_message[100],hello_tag[32];memcpy(hello_message,KG_OTA_HELLO_DOMAIN,20);memcpy(hello_message+20,nonce,16);memcpy(hello_message+36,hello_reply+20,64);
    kg_ota_hmac_sha256(key,hello_message,sizeof hello_message,hello_tag);assert(!memcmp(hello_tag,hello_reply+84,32));
    assert(!mutations);assert(keyglow_ota_reply_delivered(50));keys=0;voltage=3900;
    assert(keyglow_ota_set_authorizer(authorize));
    voltage=3700;
    assert(transact(KG_OTA_AUTH_BEGIN,3,manifest,sizeof manifest)==KEYGLOW_OTA_POWER);
    assert(!mutations);assert(keyglow_ota_reply_delivered(3));voltage=3900;

    uint8_t request[276];size_t n=frame(request,KG_OTA_AUTH_BEGIN,4,manifest,sizeof manifest);
    request[n-1]^=1;assert(!keyglow_ota_submit_frame(request,n));request[n-1]^=1;
    assert(keyglow_ota_submit_frame(request,n));assert(!keyglow_ota_submit_frame(request,n));
    keys=1;clock_ms+=501;keyglow_ota_task();assert(!mutations);
    clock_ms+=30000;keyglow_ota_task();assert(reply(4)==KEYGLOW_OTA_BUSY_TIMEOUT);assert(!mutations);
    keys=0;assert(keyglow_ota_reply_delivered(4));
    assert(transact(KG_OTA_AUTH_BEGIN,5,manifest,sizeof manifest)==KG_OTA_OK);
    assert(mutations>0);assert(keyglow_ota_reply_delivered(5));
    uint8_t copy[12];put(copy,0);put(copy+4,0);put(copy+8,sizeof image);
    n=frame(request,KG_OTA_COPY,10,copy,sizeof copy);assert(keyglow_ota_submit_frame(request,n));
    clock_ms+=501;keyglow_ota_task();uint8_t response[120];size_t response_size;
    assert(!keyglow_ota_peek_reply(response,sizeof response,&response_size));kg_ota_status progress;
    assert(kg_ota_inspect(keyglow_ota_staging_io(),&progress)==KG_OTA_OK&&(progress.missing[0]&7)==6);
    unsigned cancelled_writes=mutations;assert(keyglow_ota_cancel_pending());assert(!keyglow_ota_busy());keyglow_ota_task();assert(mutations==cancelled_writes);
    assert(keyglow_ota_submit_frame(request,n));keyglow_ota_task();assert(mutations==cancelled_writes);
    unsigned before=mutations;keys=1;keyglow_ota_note_key();keyglow_ota_task();assert(mutations==before);
    keys=0;clock_ms+=501;keyglow_ota_task();assert(!keyglow_ota_peek_reply(response,sizeof response,&response_size));
    assert(kg_ota_inspect(keyglow_ota_staging_io(),&progress)==KG_OTA_OK&&(progress.missing[0]&7)==4);
    keyglow_ota_task();assert(reply(10)==KG_OTA_OK);assert(keyglow_ota_reply_delivered(10));
    n=frame(request,KG_OTA_COPY,11,copy,sizeof copy);assert(keyglow_ota_submit_frame(request,n));keyglow_ota_task();before=mutations;
    clock_ms+=60000;keyglow_ota_task();assert(reply(11)==KEYGLOW_OTA_BUSY_TIMEOUT&&mutations==before);assert(keyglow_ota_reply_delivered(11));
    assert(transact(KG_OTA_FINISH,20,NULL,0)==KG_OTA_OK);assert(keyglow_ota_reply_delivered(20));

    /* A lost response expires rather than vetoing keyboard sleep forever. */
    assert(transact(KG_OTA_STATUS,21,NULL,0)==KG_OTA_OK);assert(keyglow_ota_busy());
    clock_ms+=60001;keyglow_ota_task();assert(!keyglow_ota_busy());
    assert(!keyglow_ota_reply_delivered(21));
    assert(transact(KG_OTA_COMMIT,30,NULL,0)==KG_OTA_OK);
    assert(!resets);clock_ms+=1000;keyglow_ota_task();assert(!resets);
    assert(!keyglow_ota_reply_delivered(31));assert(!resets);
    assert(keyglow_ota_reply_delivered(30));assert(!keyglow_ota_cancel_pending());keyglow_ota_task();assert(!resets);
    clock_ms+=1499;keyglow_ota_task();assert(!resets);clock_ms+=1;keyglow_ota_task();assert(resets==1);
    assert(!memcmp(flash,protected_snapshot,sizeof protected_snapshot));
    puts("Adapter: missing-key denial, HMAC authorization, power/key gates, COPY yielding,60s deadline/reply expiry and1500ms ACK-before-reset passed");
    return 0;
}
