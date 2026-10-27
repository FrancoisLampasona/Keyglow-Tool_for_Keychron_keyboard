/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "quantum.h"
#include "battery.h"
#include "qmk_ota_adapter.h"
#include "qmk_ota_flash.h"
#include "keyglow_ota_auth.h"
#include <string.h>
#ifndef KEYGLOW_OTA_BUILD
#define KEYGLOW_OTA_BUILD 8u
#endif

static uint8_t pending_frame[KG_OTA_FRAME_MAX],last_reply[KG_OTA_REPLY_SIZE];
static size_t pending_size;
static bool pending,processing,reply_ready,reset_pending;
static uint32_t queued_at,transaction_at,last_key_at,reset_at,reply_at;
static keyglow_ota_authorizer authorizer;
static kg_ota_copy_cursor copy_cursor;
static bool copy_started;

static uint32_t le(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put(uint8_t *p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(8*i));}

bool keyglow_ota_manifest_authorized(const kg_ota_manifest *manifest) {
    return !authorizer||authorizer(manifest);
}
bool keyglow_ota_set_authorizer(keyglow_ota_authorizer verifier) {
    syssts_t state=chSysGetStatusAndLockX();
    if(pending||processing||reply_ready||reset_pending){chSysRestoreStatusX(state);return false;}
    authorizer=verifier;chSysRestoreStatusX(state);return true;
}
static bool valid_frame(const uint8_t *frame,size_t size) {
    if(!frame||size<16||size>KG_OTA_FRAME_MAX||memcmp(frame,"KGOT",4)||frame[4]!=1)return false;
    size_t payload=(size_t)frame[6]|(size_t)frame[7]<<8;
    if(payload+16!=size||le(frame+size-4)!=kg_ota_crc32(frame,size-4))return false;
    switch(frame[5]) {
        case KG_OTA_BEGIN:return payload==49&&frame[60]<=1;
        case KG_OTA_DATA:return payload>=5&&payload<=260;
        case KG_OTA_COPY:return payload==12;
        case KG_OTA_AUTH_BEGIN:return payload==KG_OTA_AUTH_PAYLOAD&&frame[128]<=1;
        case KG_OTA_HELLO:return payload==16;
        case KG_OTA_STATUS:case KG_OTA_FINISH:case KG_OTA_COMMIT:return payload==0;
        default:return false;
    }
}
bool keyglow_ota_submit_frame(const uint8_t *frame,size_t size) {
    if(!valid_frame(frame,size))return false;
    syssts_t state=chSysGetStatusAndLockX();
    if(pending||processing||reply_ready||reset_pending){chSysRestoreStatusX(state);return false;}
    memcpy(pending_frame,frame,size);pending_size=size;queued_at=transaction_at=timer_read32();pending=true;copy_started=false;
    chSysRestoreStatusX(state);return true;
}
bool keyglow_ota_peek_reply(uint8_t *out,size_t capacity,size_t *size) {
    if(!out||!size||capacity<KG_OTA_REPLY_SIZE)return false;
    syssts_t state=chSysGetStatusAndLockX();
    bool ready=reply_ready;
    if(ready){memcpy(out,last_reply,KG_OTA_REPLY_SIZE);*size=KG_OTA_REPLY_SIZE;}
    chSysRestoreStatusX(state);return ready;
}
bool keyglow_ota_reply_delivered(uint32_t request_id) {
    syssts_t state=chSysGetStatusAndLockX();
    if(!reply_ready||le(last_reply+8)!=request_id){chSysRestoreStatusX(state);return false;}
    /* Caller must wait for actual transport acknowledgement. Merely queueing
     * a reply is not delivery. COMMIT never resets before this callback. */
    if(last_reply[5]==(KG_OTA_COMMIT|0x80)&&le(last_reply+12)==KG_OTA_OK) {
        reset_pending=true;reset_at=timer_read32();
    }
    reply_ready=false;chSysRestoreStatusX(state);return true;
}
bool keyglow_ota_busy(void) {
    syssts_t state=chSysGetStatusAndLockX();bool busy=pending||processing||reply_ready||reset_pending;
    chSysRestoreStatusX(state);return busy;
}
bool keyglow_ota_cancel_pending(void) {
    syssts_t state=chSysGetStatusAndLockX();
    if(processing||reset_pending){chSysRestoreStatusX(state);return false;}
    pending=false;reply_ready=false;copy_started=false;pending_size=0;
    chSysRestoreStatusX(state);return true;
}
void keyglow_ota_note_key(void){last_key_at=timer_read32();}
static bool keyboard_idle(void) {
    if(timer_elapsed32(last_key_at)<500u||get_mods()||get_weak_mods())return false;
    for(uint8_t r=0;r<MATRIX_ROWS;r++)if(matrix_get_row(r))return false;
    return true;
}
static bool enough_power(void) {
    if(readPin(USB_POWER_SENSE_PIN)==USB_POWER_CONNECTED_LEVEL)return true;
    return battery_has_valid_reading()&&!battery_power_on_sample()&&!battery_is_critical_low()&&battery_get_voltage()>=3800u;
}
static bool authorized(const uint8_t key[32]) {
    kg_ota_manifest m;
    if(pending_frame[5]==KG_OTA_BEGIN)return false;
    if(pending_frame[5]==KG_OTA_AUTH_BEGIN) {
        kg_ota_authorization a;
        if(!kg_ota_auth_decode(pending_frame+12,&a)||!kg_ota_auth_valid(key,&a))return false;
        m=a.manifest;
    } else {
        kg_ota_status s;if(kg_ota_check_authorization(keyglow_ota_staging_io(),key)!=KG_OTA_OK||kg_ota_inspect(keyglow_ota_staging_io(),&s)!=KG_OTA_OK)return false;m=s.manifest;
    }
    return m.target==KG_OTA_TARGET&&m.address==KG_OTA_APP_BASE&&m.length>=8&&m.length<=KG_OTA_APP_MAX&&keyglow_ota_manifest_authorized(&m);
}
static void rejection(uint32_t error) {
    uint8_t request[16]={'K','G','O','T',1,KG_OTA_STATUS};size_t length=0;
    put(request+8,le(pending_frame+8));put(request+12,kg_ota_crc32(request,12));
    (void)kg_ota_handle_frame(keyglow_ota_staging_io(),request,sizeof request,last_reply,sizeof last_reply,&length);
    last_reply[5]=pending_frame[5]|0x80;put(last_reply+12,error);put(last_reply+116,kg_ota_crc32(last_reply,116));
}
void keyglow_ota_task(void) {
    syssts_t state=chSysGetStatusAndLockX();
    bool reset_due=reset_pending&&timer_elapsed32(reset_at)>=1500u;
    chSysRestoreStatusX(state);
    if(reset_due){NVIC_SystemReset();return;}
    state=chSysGetStatusAndLockX();
    /* A disconnected transport must not keep the keyboard awake indefinitely.
     * Durable state remains available to STATUS/BEGIN after reconnect. */
    if(reply_ready&&timer_elapsed32(reply_at)>=60000u)reply_ready=false;
    if(!pending||processing||reply_ready||reset_pending){chSysRestoreStatusX(state);return;}
    chSysRestoreStatusX(state);
    /* This function runs in the foreground matrix scan, never in an ISR. */
    bool status=pending_frame[5]==KG_OTA_STATUS,hello=pending_frame[5]==KG_OTA_HELLO,read_only=status||hello;
    if(!read_only&&!keyboard_idle()&&timer_elapsed32(queued_at)<30000u&&timer_elapsed32(transaction_at)<60000u)return;
    state=chSysGetStatusAndLockX();processing=true;pending=false;chSysRestoreStatusX(state);
    size_t size=0;
    uint8_t key[32]={0};bool have_key=status||kg_ota_read_device_key(keyglow_ota_staging_io(),key);
    if(!status&&timer_elapsed32(transaction_at)>=60000u)rejection(KEYGLOW_OTA_BUSY_TIMEOUT);
    else if(!status&&(!keyglow_ota_flash_target_valid()||!have_key||(!hello&&!authorized(key))))rejection(KEYGLOW_OTA_UNAUTHORIZED);
    else if(!read_only&&!enough_power())rejection(KEYGLOW_OTA_POWER);
    else if(!read_only&&!keyboard_idle())rejection(KEYGLOW_OTA_BUSY_TIMEOUT);
    else if(hello) {
        memset(last_reply,0,sizeof last_reply);memcpy(last_reply,"KGOT",4);last_reply[4]=1;last_reply[5]=KG_OTA_HELLO|0x80;last_reply[6]=104;
        put(last_reply+8,le(pending_frame+8));
        kg_ota_result result=kg_ota_hello(keyglow_ota_staging_io(),key,keyglow_ota_application_length(),KEYGLOW_OTA_BUILD,pending_frame+12,last_reply+20);
        put(last_reply+12,(uint32_t)result);put(last_reply+116,kg_ota_crc32(last_reply,116));
    }
    else if(pending_frame[5]==KG_OTA_COPY) {
        kg_ota_result result=KG_OTA_OK;bool complete=false;
        if(!copy_started) {
            result=kg_ota_copy_start(keyglow_ota_staging_io(),le(pending_frame+12),le(pending_frame+16),le(pending_frame+20),&copy_cursor);
            copy_started=result==KG_OTA_OK;
        }
        if(result==KG_OTA_OK)result=kg_ota_copy_step(keyglow_ota_staging_io(),&copy_cursor,&complete);
        if(result==KG_OTA_OK&&!complete) {
            /* One durable chunk per foreground scan. Key activity pauses the
             * next chunk; retransmission resumes the persisted bitmap. */
            for(unsigned i=0;i<sizeof key;i++)((volatile uint8_t *)key)[i]=0;
            state=chSysGetStatusAndLockX();processing=false;pending=true;queued_at=timer_read32();chSysRestoreStatusX(state);return;
        }
        rejection((uint32_t)result);
    }
    else if(!kg_ota_handle_authenticated_frame(keyglow_ota_staging_io(),key,pending_frame,pending_size,last_reply,sizeof last_reply,&size))rejection(KG_OTA_BOUNDS);
    for(unsigned i=0;i<sizeof key;i++)((volatile uint8_t *)key)[i]=0;
    state=chSysGetStatusAndLockX();processing=false;reply_at=timer_read32();reply_ready=true;chSysRestoreStatusX(state);
}
