/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota.h"
#include "keyglow_ota_wire.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint8_t flash[256*1024],saved[256*1024],target[4353];
static unsigned writes,cut_at,cut_mode;
static bool reject_source_read;
static void put(uint8_t *p,uint32_t value){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(value>>(8*i));}
static bool read_flash(void *context,uint32_t address,void *bytes,size_t length){
    (void)context;
    assert(address>=KG_OTA_FLASH_BASE&&address<=KG_OTA_FLASH_END&&length<=KG_OTA_FLASH_END-address);
    if(reject_source_read&&address>=KG_OTA_APP_BASE&&address<KG_OTA_STAGE_BASE)return false;
    memcpy(bytes,flash+(address-KG_OTA_FLASH_BASE),length);return true;
}
static bool program_flash(void *context,uint32_t address,uint32_t word){
    (void)context;assert(!(address&3)&&address>=KG_OTA_STAGE_BASE&&address<=KG_OTA_FLASH_END-4);
    uint8_t bytes[4];put(bytes,word);uint8_t *destination=flash+(address-KG_OTA_FLASH_BASE);
    bool cut=++writes==cut_at;
    for(unsigned i=0;i<4;i++)assert((destination[i]&bytes[i])==bytes[i]);
    if(!cut||cut_mode==4)for(unsigned i=0;i<4;i++)destination[i]&=bytes[i];
    else if(cut_mode<4)for(unsigned i=0;i<cut_mode;i++)destination[i]&=bytes[i];
    else for(unsigned i=0;i<4;i++)destination[i]&=(uint8_t)(bytes[i]|(cut_mode==5?0x55:0xaa));
    return !cut;
}
static bool erase_flash(void *context,unsigned sector){(void)context;assert(sector==5);memset(flash+128*1024,255,128*1024);return true;}
static const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};
static kg_ota_manifest setup(unsigned length,uint32_t source){
    assert(length<=sizeof target&&source<=KG_OTA_APP_MAX-length);
    memset(flash,0x5a,sizeof flash);memset(flash+128*1024,255,128*1024);
    for(unsigned i=0;i<length;i++)target[i]=(uint8_t)(i*37u+11u);
    put(target,0x20010000);put(target+4,KG_OTA_APP_BASE+9);
    memcpy(flash+(KG_OTA_APP_BASE-KG_OTA_FLASH_BASE)+source,target,length);
    kg_ota_manifest manifest={KG_OTA_TARGET,KG_OTA_APP_BASE,length,9,{0}};
    kg_ota_sha256(target,length,manifest.sha256);
    writes=cut_at=0;reject_source_read=false;
    assert(kg_ota_begin(&io,&manifest,false)==KG_OTA_OK);writes=0;
    return manifest;
}
static void bounded_incremental(void){
    (void)setup(4353,17);kg_ota_copy_cursor cursor;bool complete=true;
    assert(kg_ota_copy_start(&io,0,17,4096,&cursor)==KG_OTA_OK);assert(!writes);
    for(unsigned i=0;i<16;i++){
        assert(kg_ota_copy_step(&io,&cursor,&complete)==KG_OTA_OK);
        assert(complete==(i==15));kg_ota_status status;assert(kg_ota_inspect(&io,&status)==KG_OTA_OK);
        for(unsigned chunk=0;chunk<18;chunk++)assert(((status.missing[chunk/8]>>(chunk%8))&1)==(chunk>i));
    }
    unsigned before=writes;assert(kg_ota_copy_step(&io,&cursor,&complete)==KG_OTA_OK&&complete);assert(writes==before);
    assert(kg_ota_copy(&io,4096,4113,257)==KG_OTA_OK);
    assert(kg_ota_finish(&io)==KG_OTA_OK);
    before=writes;assert(kg_ota_copy(&io,0,17,4096)==KG_OTA_OK);assert(writes==before);
    assert(!memcmp(flash+128*1024+256,target,4353));
    puts("COPY: unaligned bounded source, 4096-byte runs, final tail and one durable chunk per step passed");
}
static void bounds_and_conflicts(void){
    kg_ota_manifest manifest=setup(1031,3);unsigned before=writes;
    const uint32_t bad[][3]={{0,0,0},{0,0,4097},{1,0,256},{1024,0,8},{0,0,255},
        {0,KG_OTA_APP_MAX,256},{0,KG_OTA_APP_MAX-255,256},{UINT32_MAX,0,256},
        {0,UINT32_MAX,256},{0,0,UINT32_MAX},{0,KG_OTA_STAGE_BASE,256},{0,KG_OTA_FLASH_BASE,256}};
    for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++)assert(kg_ota_copy(&io,bad[i][0],bad[i][1],bad[i][2])==KG_OTA_BOUNDS);
    assert(writes==before);
    kg_ota_copy_cursor cursor;bool complete;
    assert(kg_ota_copy_start(&io,0,3,1031,&cursor)==KG_OTA_OK);
    reject_source_read=true;assert(kg_ota_copy_step(&io,&cursor,&complete)==KG_OTA_IO&&!complete);assert(writes==before);
    reject_source_read=false;cursor.source=UINT32_MAX;assert(kg_ota_copy_step(&io,&cursor,&complete)==KG_OTA_BOUNDS);assert(writes==before);
    assert(kg_ota_copy_start(&io,0,3,1031,&cursor)==KG_OTA_OK);
    manifest.build++;assert(kg_ota_begin(&io,&manifest,true)==KG_OTA_OK);before=writes;
    assert(kg_ota_copy_step(&io,&cursor,&complete)==KG_OTA_CONFLICT);assert(writes==before);

    /* A wrong baseline can pass frame CRC and chunk writes, never final SHA. */
    manifest=setup(1031,3);flash[KG_OTA_APP_BASE-KG_OTA_FLASH_BASE+3+20]^=1;
    assert(kg_ota_copy(&io,0,3,1031)==KG_OTA_OK);assert(kg_ota_finish(&io)==KG_OTA_DIGEST);
    assert(kg_ota_chunk(&io,0,target,256)==KG_OTA_CONFLICT);
    assert(kg_ota_begin(&io,&manifest,true)==KG_OTA_OK);
    memcpy(flash+(KG_OTA_APP_BASE-KG_OTA_FLASH_BASE)+3,target,1031);
    assert(kg_ota_copy(&io,0,3,1031)==KG_OTA_OK);assert(kg_ota_finish(&io)==KG_OTA_OK);
    assert(kg_ota_commit(&io)==KG_OTA_OK);before=writes;
    assert(kg_ota_copy(&io,0,3,1031)==KG_OTA_OK);assert(writes==before);
    flash[KG_OTA_APP_BASE-KG_OTA_FLASH_BASE+3+20]^=1;
    assert(kg_ota_copy(&io,0,3,1031)==KG_OTA_CONFLICT);assert(writes==before);
    puts("COPY: overflow/read isolation, changed session, incorrect baseline digest and commit barrier passed");
}
static void interruption_tests(void){
    (void)setup(1031,17);memcpy(saved,flash,sizeof saved);
    assert(kg_ota_copy(&io,0,17,1031)==KG_OTA_OK);unsigned total=writes;
    for(unsigned mode=0;mode<7;mode++)for(unsigned cut=1;cut<=total;cut++){
        memcpy(flash,saved,sizeof flash);writes=0;cut_at=cut;cut_mode=mode;
        assert(kg_ota_copy(&io,0,17,1031)==KG_OTA_IO);
        cut_at=0;assert(kg_ota_copy(&io,0,17,1031)==KG_OTA_OK);
        assert(kg_ota_finish(&io)==KG_OTA_OK);
        assert(!memcmp(flash,saved,KG_OTA_STAGE_BASE-KG_OTA_FLASH_BASE));
        assert(!memcmp(flash+128*1024+256,target,1031));
    }
    printf("COPY: %u mutation points × 7 byte/bit interruption modes resumed; application/loader/EEPROM preserved\n",total);
}
static void wire_test(void){
    (void)setup(1031,17);uint8_t frame[28]={'K','G','O','T',1,KG_OTA_COPY,12,0,42},reply[120];size_t length;
    put(frame+12,0);put(frame+16,17);put(frame+20,1031);put(frame+24,kg_ota_crc32(frame,24));
    frame[24]^=1;assert(!kg_ota_handle_frame(&io,frame,sizeof frame,reply,sizeof reply,&length));assert(!writes);frame[24]^=1;
    assert(kg_ota_handle_frame(&io,frame,sizeof frame,reply,sizeof reply,&length));
    assert(length==120&&reply[5]==(KG_OTA_COPY|0x80)&&reply[8]==42&&reply[12]==KG_OTA_OK);
    assert(kg_ota_finish(&io)==KG_OTA_OK);
    puts("COPY: opcode 6, 12-byte payload, 28-byte request framing and CRC rejection passed");
}
static void full_application_copy(void){
    memset(flash,0x5a,sizeof flash);memset(flash+128*1024,255,128*1024);
    uint8_t *source=flash+(KG_OTA_APP_BASE-KG_OTA_FLASH_BASE);
    put(source,0x20010000);put(source+4,KG_OTA_APP_BASE+9);
    kg_ota_manifest manifest={KG_OTA_TARGET,KG_OTA_APP_BASE,KG_OTA_APP_MAX,10,{0}};
    kg_ota_sha256(source,manifest.length,manifest.sha256);cut_at=0;reject_source_read=false;
    assert(kg_ota_begin(&io,&manifest,false)==KG_OTA_OK);
    assert(kg_ota_copy(&io,0,0,KG_OTA_APP_MAX)==KG_OTA_OK);
    assert(kg_ota_finish(&io)==KG_OTA_OK);
    assert(!memcmp(source,flash+128*1024+256,KG_OTA_APP_MAX));
    unsigned before=writes;assert(kg_ota_copy(&io,0,0,KG_OTA_APP_MAX+1)==KG_OTA_BOUNDS);assert(writes==before);
    puts("COPY: one96KiB request completes384 independently durable steps without application writes");
}
int main(void){bounded_incremental();bounds_and_conflicts();interruption_tests();wire_test();full_application_copy();return 0;}
