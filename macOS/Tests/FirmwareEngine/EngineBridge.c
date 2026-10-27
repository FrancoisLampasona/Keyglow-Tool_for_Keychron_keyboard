/* SPDX-License-Identifier: GPL-2.0-or-later
 * Offline child process. Public synthetic key; RAM-backed flash only. */
#include "keyglow_ota_auth.h"
#include "keyglow_ota_wire.h"
#include "keyglow_ble_wire.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static uint8_t flash[262144], key[32];
static uint32_t current_length, current_build=8;
static bool rd(void *c,uint32_t a,void *out,size_t n){(void)c;if(a<KG_OTA_FLASH_BASE||a>KG_OTA_FLASH_END||n>KG_OTA_FLASH_END-a)return false;memcpy(out,flash+(a-KG_OTA_FLASH_BASE),n);return true;}
static bool wr(void *c,uint32_t a,uint32_t w){(void)c;if(a<KG_OTA_APP_BASE||a>KG_OTA_FLASH_END-4||(a&3))return false;for(unsigned i=0;i<4;i++){uint8_t *p=&flash[a-KG_OTA_FLASH_BASE+i],v=(uint8_t)(w>>(8*i));if((*p&v)!=v)return false;*p=v;}return true;}
static bool erase(void *c,unsigned s){(void)c;static const unsigned boundaries[]={0,16384,32768,49152,65536,131072,262144};if(s<2||s>5)return false;memset(flash+boundaries[s],255,boundaries[s+1]-boundaries[s]);return true;}
static const kg_ota_io io={NULL,rd,wr,erase};
static void initial_installed_stage(const uint8_t *image,size_t n){
    kg_ota_authorization a={0};a.manifest.target=KG_OTA_TARGET;a.manifest.address=KG_OTA_APP_BASE;a.manifest.length=(uint32_t)n;a.manifest.build=8;
    kg_ota_sha256(image,n,a.manifest.sha256);a.source_length=(uint32_t)n;memcpy(a.source_sha256,a.manifest.sha256,32);
    uint8_t digest[32],payload[149],message[136];kg_ota_sha256(key,32,digest);memcpy(a.key_id,digest,16);memset(a.nonce,0x42,16);
    kg_ota_auth_encode(&a,payload);memcpy(message,KG_OTA_AUTH_DOMAIN,19);memcpy(message+19,payload,117);kg_ota_hmac_sha256(key,message,sizeof message,a.tag);
    assert(kg_ota_begin_authenticated(&io,key,&a)==KG_OTA_OK);
    for(size_t offset=0;offset<n;offset+=256)assert(kg_ota_chunk(&io,(uint32_t)offset,image+offset,n-offset>256?256:n-offset)==KG_OTA_OK);
    assert(kg_ota_finish(&io)==KG_OTA_OK);assert(kg_ota_commit(&io)==KG_OTA_OK);assert(kg_ota_install_authenticated(&io,key)==KG_OTA_OK);
}
int main(int argc,char **argv){
    assert(argc==2);FILE *f=fopen(argv[1],"rb");assert(f);uint8_t image[KG_OTA_APP_MAX];size_t size=fread(image,1,sizeof image,f);assert(feof(f));fclose(f);
    assert(size>=8);memset(flash,255,sizeof flash);memcpy(flash+32768,image,size);current_length=(uint32_t)size;
    for(unsigned i=0;i<32;i++)key[i]=(uint8_t)(i+1);initial_installed_stage(image,size);
    char line[KG_OTA_FRAME_MAX*2+4];
    while(fgets(line,sizeof line,stdin)){
        size_t n=strcspn(line,"\r\n");assert(n%2==0&&n/2<=KG_OTA_FRAME_MAX);uint8_t request[KG_OTA_FRAME_MAX],reply[KG_BLE_ACK_MAX];size_t written=0;
        for(size_t i=0;i<n/2;i++){unsigned value;assert(sscanf(line+i*2,"%2x",&value)==1);request[i]=(uint8_t)value;}
        assert(kg_ble_request_valid(request,n/2));uint32_t id=(uint32_t)request[8]|(uint32_t)request[9]<<8|(uint32_t)request[10]<<16|(uint32_t)request[11]<<24;
        if(request[5]==KG_OTA_HELLO){uint8_t payload[96];assert(kg_ota_hello(&io,key,current_length,current_build,request+12,payload)==KG_OTA_OK);assert(kg_ble_ack_encode(8,id,0,0,payload,96,reply,sizeof reply,&written));}
        else {uint8_t legacy[120];size_t length=0;assert(kg_ota_handle_authenticated_frame(&io,key,request,n/2,legacy,sizeof legacy,&length));assert(kg_ble_ack_from_legacy(legacy,length,request[5]==3,reply,sizeof reply,&written));}
        for(size_t i=0;i<written;i++)printf("%02x",reply[i]);puts("");fflush(stdout);
        if(request[5]==KG_OTA_COMMIT&&reply[10]==0){kg_ota_status state;assert(kg_ota_inspect(&io,&state)==KG_OTA_OK);assert(kg_ota_install_authenticated(&io,key)==KG_OTA_OK);current_length=state.manifest.length;current_build=state.manifest.build;}
    }
    return 0;
}
