/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota_wire.h"
#include "keyglow_ota_auth.h"
#include <string.h>
static uint32_t le(const uint8_t *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static void put(uint8_t *p,uint32_t n) { for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(8*i)); }
static void encode(uint8_t *p,const kg_ota_manifest *m) { put(p,m->target);put(p+4,m->address);put(p+8,m->length);put(p+12,m->build);memcpy(p+16,m->sha256,32); }
static bool handle(const kg_ota_io *io,const uint8_t *key,bool secure,const uint8_t *in,size_t n,uint8_t *out,size_t capacity,size_t *written) {
    if(written)*written=0;
    if(!in||!out||!written||capacity<KG_OTA_REPLY_SIZE||n<16||n>KG_OTA_FRAME_MAX||memcmp(in,"KGOT",4)||in[4]!=1)return false;
    size_t payload=(size_t)in[6]|(size_t)in[7]<<8;
    if(payload+16!=n||le(in+n-4)!=kg_ota_crc32(in,n-4))return false;
    const uint8_t *p=in+12;uint8_t op=in[5];uint32_t request_id=le(in+8);kg_ota_result r;
    /* Validate operation payloads before policy or writes. */
    switch(op){
    case KG_OTA_BEGIN:if(payload!=49||p[48]>1)return false;break;
    case KG_OTA_DATA:if(payload<5||payload>260)return false;break;
    case KG_OTA_STATUS:case KG_OTA_FINISH:case KG_OTA_COMMIT:if(payload)return false;break;
    case KG_OTA_COPY:if(payload!=12)return false;break;
    case KG_OTA_AUTH_BEGIN:if(!secure||payload!=KG_OTA_AUTH_PAYLOAD||p[116]>1)return false;break;
    default:return false;
    }
    if(secure&&op==KG_OTA_BEGIN)r=KG_OTA_AUTH_ERROR;
    else if(secure&&op!=KG_OTA_STATUS&&op!=KG_OTA_AUTH_BEGIN&&(r=kg_ota_check_authorization(io,key))!=KG_OTA_OK){/* authenticated session required */}
    else switch(op) {
    case KG_OTA_BEGIN: {
        if(payload!=49||p[48]>1)return false;
        kg_ota_manifest m={.target=le(p),.address=le(p+4),.length=le(p+8),.build=le(p+12)};memcpy(m.sha256,p+16,32);
        r=kg_ota_begin(io,&m,p[48]!=0);break;
    }
    case KG_OTA_DATA: if(payload<5||payload>260)return false;r=kg_ota_chunk(io,le(p),p+4,payload-4);break;
    case KG_OTA_STATUS: { if(payload)return false;kg_ota_status s;r=kg_ota_inspect(io,&s);break; }
    case KG_OTA_FINISH: if(payload)return false;r=kg_ota_finish(io);break;
    case KG_OTA_COMMIT: if(payload)return false;r=kg_ota_commit(io);break;
    case KG_OTA_COPY: if(payload!=12)return false;r=kg_ota_copy(io,le(p),le(p+4),le(p+8));break;
    case KG_OTA_AUTH_BEGIN:{kg_ota_authorization a;if(!kg_ota_auth_decode(p,&a))return false;r=kg_ota_begin_authenticated(io,key,&a);break;}
    default: return false;
    }
    kg_ota_status status;kg_ota_result sr=kg_ota_inspect(io,&status);
    /* A failed post-write read must never become a success acknowledgement. */
    if(sr!=KG_OTA_OK&&r==KG_OTA_OK)r=sr;
    memset(out,0,KG_OTA_REPLY_SIZE);memcpy(out,"KGOT",4);out[4]=1;out[5]=op|0x80;out[6]=104;put(out+8,request_id);put(out+12,(uint32_t)r);
    if(sr==KG_OTA_OK){put(out+16,1u|(status.ready?2u:0u)|(status.committed?4u:0u)|(status.installed?8u:0u));encode(out+20,&status.manifest);memcpy(out+68,status.missing,48);}
    put(out+116,kg_ota_crc32(out,116));*written=KG_OTA_REPLY_SIZE;return true;
}
bool kg_ota_handle_frame(const kg_ota_io *io,const uint8_t *in,size_t n,uint8_t *out,size_t capacity,size_t *written){return handle(io,NULL,false,in,n,out,capacity,written);}
bool kg_ota_handle_authenticated_frame(const kg_ota_io *io,const uint8_t key[32],const uint8_t *in,size_t n,uint8_t *out,size_t capacity,size_t *written){return handle(io,key,true,in,n,out,capacity,written);}
