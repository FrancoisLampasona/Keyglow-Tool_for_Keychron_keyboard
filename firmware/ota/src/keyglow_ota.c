/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota.h"
#include "sha256.h"
#include <string.h>

enum { H_SEAL=68, H_READY=72, H_COMMIT=76, H_DONE=80, H_BITMAP=128 };
#define SEALED UINT32_C(0xa71a0a7a)
#define MARK UINT32_C(0xfffffffe)
static const uint8_t magic[8]={'K','G','O','T','A','0','0','1'};
static uint32_t le(const uint8_t *b) { return (uint32_t)b[0]|(uint32_t)b[1]<<8|(uint32_t)b[2]<<16|(uint32_t)b[3]<<24; }
static void put(uint8_t *b,uint32_t v) { for(unsigned i=0;i<4;i++)b[i]=(uint8_t)(v>>(8*i)); }
static bool read_at(const kg_ota_io *io,uint32_t a,void *p,size_t n) {
    return io && io->read && a>=KG_OTA_FLASH_BASE && a<=KG_OTA_FLASH_END && n<=KG_OTA_FLASH_END-a && io->read(io->context,a,p,n);
}
static kg_ota_result program(const kg_ota_io *io,uint32_t a,uint32_t v) {
    uint8_t b[4];
    if((a&3u)||a<KG_OTA_APP_BASE||a>KG_OTA_FLASH_END-4u)return KG_OTA_BOUNDS;
    if(!read_at(io,a,b,4))return KG_OTA_IO;
    uint32_t old=le(b);
    if(old==v)return KG_OTA_OK;
    if((old&v)!=v)return KG_OTA_CONFLICT;
    if(!io->program_word||!io->program_word(io->context,a,v)||!read_at(io,a,b,4)||le(b)!=v)return KG_OTA_IO;
    return KG_OTA_OK;
}
static kg_ota_result mark(const kg_ota_io *io,unsigned offset) { return program(io,KG_OTA_STAGE_BASE+offset,MARK); }
static kg_ota_result valid_manifest(const kg_ota_manifest *m) {
    if(!m||m->target!=KG_OTA_TARGET)return KG_OTA_TARGET_ERROR;
    if(m->address!=KG_OTA_APP_BASE||m->length<8||m->length>KG_OTA_APP_MAX)return KG_OTA_BOUNDS;
    return KG_OTA_OK;
}
static bool same(const kg_ota_manifest *a,const kg_ota_manifest *b) {
    return a->target==b->target&&a->address==b->address&&a->length==b->length&&a->build==b->build&&!memcmp(a->sha256,b->sha256,32);
}
kg_ota_result kg_ota_inspect(const kg_ota_io *io,kg_ota_status *s) {
    uint8_t h[KG_OTA_HEADER_SIZE];
    if(!s)return KG_OTA_BOUNDS;
    if(!read_at(io,KG_OTA_STAGE_BASE,h,sizeof h))return KG_OTA_IO;
    memset(s,0,sizeof *s);
    if(memcmp(h,magic,8)||le(h+8)!=1||le(h+28)!=KG_OTA_CHUNK_SIZE||le(h+H_SEAL)!=SEALED||le(h+64)!=kg_ota_crc32(h,64))return KG_OTA_NO_SESSION;
    s->manifest.target=le(h+12);s->manifest.address=le(h+16);s->manifest.length=le(h+20);s->manifest.build=le(h+24);memcpy(s->manifest.sha256,h+32,32);
    kg_ota_result r=valid_manifest(&s->manifest);if(r!=KG_OTA_OK)return r;
    /* Unknown/torn state markers fail closed rather than implying readiness. */
    for(unsigned i=H_READY;i<=H_DONE;i+=4)if(le(h+i)!=UINT32_MAX&&le(h+i)!=MARK)return KG_OTA_CONFLICT;
    s->ready=le(h+H_READY)==MARK;s->committed=le(h+H_COMMIT)==MARK;s->installed=le(h+H_DONE)==MARK;
    if((s->committed&&!s->ready)||(s->installed&&!s->committed))return KG_OTA_CONFLICT;
    memcpy(s->missing,h+H_BITMAP,KG_OTA_BITMAP_BYTES);
    return KG_OTA_OK;
}
kg_ota_result kg_ota_begin(const kg_ota_io *io,const kg_ota_manifest *m,bool replace) {
    kg_ota_result r=valid_manifest(m);if(r!=KG_OTA_OK)return r;
    kg_ota_status s;r=kg_ota_inspect(io,&s);
    if(r==KG_OTA_IO)return r;
    if(r==KG_OTA_OK) {
        if(same(m,&s.manifest)&&!replace)return KG_OTA_OK;
        if(s.committed&&!s.installed)return KG_OTA_COMMIT_PENDING;
        /* An explicit replacement restarts an uncommitted session, including
         * the same manifest after a CRC-valid but incorrect chunk. Already
         * installed identical images remain idempotent to avoid flash wear. */
        if(same(m,&s.manifest)&&s.installed)return KG_OTA_OK;
        if(!replace)return KG_OTA_CONFLICT;
    } else if(r!=KG_OTA_NO_SESSION) return r;
    if(!io->erase_sector||!io->erase_sector(io->context,5))return KG_OTA_IO;
    /* Check the entire erase, including future data; power loss cannot leave
     * stale bits underneath a valid new header. */
    uint8_t b[256];
    for(uint32_t a=KG_OTA_STAGE_BASE;a<KG_OTA_FLASH_END;a+=sizeof b){if(!read_at(io,a,b,sizeof b))return KG_OTA_IO;for(unsigned i=0;i<sizeof b;i++)if(b[i]!=255)return KG_OTA_IO;}
    uint8_t h[72];memset(h,255,sizeof h);memcpy(h,magic,8);put(h+8,1);put(h+12,m->target);put(h+16,m->address);put(h+20,m->length);put(h+24,m->build);put(h+28,KG_OTA_CHUNK_SIZE);memcpy(h+32,m->sha256,32);put(h+64,kg_ota_crc32(h,64));put(h+H_SEAL,SEALED);
    /* Seal is the final word. An interrupted header is not a valid session. */
    for(unsigned i=0;i<sizeof h;i+=4){r=program(io,KG_OTA_STAGE_BASE+i,le(h+i));if(r!=KG_OTA_OK)return r;}
    return KG_OTA_OK;
}
kg_ota_result kg_ota_chunk(const kg_ota_io *io,uint32_t offset,const uint8_t *data,size_t length) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(!data||(offset%KG_OTA_CHUNK_SIZE)||offset>=s.manifest.length)return KG_OTA_BOUNDS;
    size_t expected=s.manifest.length-offset;if(expected>KG_OTA_CHUNK_SIZE)expected=KG_OTA_CHUNK_SIZE;
    if(length!=expected)return KG_OTA_BOUNDS;
    uint32_t chunk=offset/KG_OTA_CHUNK_SIZE,a=KG_OTA_STAGE_BASE+KG_OTA_HEADER_SIZE+offset;
    uint8_t b[KG_OTA_CHUNK_SIZE];if(!read_at(io,a,b,length))return KG_OTA_IO;
    bool missing=(s.missing[chunk/8]&(1u<<(chunk%8)))!=0;
    if(!missing)return memcmp(b,data,length)?KG_OTA_CONFLICT:KG_OTA_OK;
    if(s.ready||s.committed)return KG_OTA_CONFLICT;
    /* Preflight the whole chunk so a conflicting retransmission cannot make
     * an otherwise resumable partial chunk worse. */
    for(size_t i=0;i<length;i++)if((b[i]&data[i])!=data[i])return KG_OTA_CONFLICT;
    for(size_t i=0;i<length;i+=4){uint8_t w[4]={255,255,255,255};size_t n=length-i;if(n>4)n=4;memcpy(w,data+i,n);r=program(io,a+(uint32_t)i,le(w));if(r!=KG_OTA_OK)return r;}
    if(!read_at(io,a,b,length)||memcmp(b,data,length))return KG_OTA_IO;
    unsigned byte=chunk/8,word=byte&~3u;uint8_t bits[4];
    memcpy(bits,s.missing+word,4);bits[byte-word]&=(uint8_t)~(1u<<(chunk%8));
    return program(io,KG_OTA_STAGE_BASE+H_BITMAP+word,le(bits));
}
static kg_ota_result digest_matches(const kg_ota_io *io,uint32_t a,const kg_ota_manifest *m) {
    uint8_t b[256],out[32];uint32_t left=m->length;kg_sha sha;kg_sha_init(&sha);
    while(left){size_t n=left>sizeof b?sizeof b:left;if(!read_at(io,a,b,n))return KG_OTA_IO;kg_sha_update(&sha,b,n);a+=(uint32_t)n;left-=(uint32_t)n;}
    kg_sha_final(&sha,out);return memcmp(out,m->sha256,32)?KG_OTA_DIGEST:KG_OTA_OK;
}
bool kg_ota_vectors_valid(const kg_ota_io *io,uint32_t storage,uint32_t length) {
    uint8_t b[8];if(length<8||length>KG_OTA_APP_MAX||!read_at(io,storage,b,8))return false;
    uint32_t sp=le(b),reset=le(b+4),pc=reset&~1u;
    return sp>=0x20000008u&&sp<=0x20010000u&&!(sp&7u)&&(reset&1u)&&pc>=KG_OTA_APP_BASE+8u&&pc<KG_OTA_APP_BASE+length;
}
static kg_ota_result verify_stage(const kg_ota_io *io,const kg_ota_status *s) {
    unsigned count=(s->manifest.length+KG_OTA_CHUNK_SIZE-1)/KG_OTA_CHUNK_SIZE;
    for(unsigned i=0;i<count;i++)if(s->missing[i/8]&(1u<<(i%8)))return KG_OTA_INCOMPLETE;
    kg_ota_result r=digest_matches(io,KG_OTA_STAGE_BASE+KG_OTA_HEADER_SIZE,&s->manifest);if(r!=KG_OTA_OK)return r;
    return kg_ota_vectors_valid(io,KG_OTA_STAGE_BASE+KG_OTA_HEADER_SIZE,s->manifest.length)?KG_OTA_OK:KG_OTA_VECTOR;
}
kg_ota_result kg_ota_finish(const kg_ota_io *io) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    r=verify_stage(io,&s);return r==KG_OTA_OK?mark(io,H_READY):r;
}
kg_ota_result kg_ota_commit(const kg_ota_io *io) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(!s.ready)return KG_OTA_NOT_READY;
    r=verify_stage(io,&s);return r==KG_OTA_OK?mark(io,H_COMMIT):r;
}
kg_ota_result kg_ota_install(const kg_ota_io *io) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(!s.committed)return KG_OTA_NOT_READY;
    r=verify_stage(io,&s);if(r!=KG_OTA_OK)return r;
    r=digest_matches(io,KG_OTA_APP_BASE,&s.manifest);
    if(r==KG_OTA_IO)return r;
    if(r!=KG_OTA_OK) {
        /* Staging and loader are deliberately never erased by the installer. */
        if(!io->erase_sector)return KG_OTA_IO;
        for(unsigned sector=2;sector<=4;sector++)if(!io->erase_sector(io->context,sector))return KG_OTA_IO;
        for(uint32_t offset=0;offset<s.manifest.length;offset+=4){uint8_t w[4]={255,255,255,255};size_t n=s.manifest.length-offset;if(n>4)n=4;if(!read_at(io,KG_OTA_STAGE_BASE+KG_OTA_HEADER_SIZE+offset,w,n))return KG_OTA_IO;r=program(io,KG_OTA_APP_BASE+offset,le(w));if(r!=KG_OTA_OK)return r;}
        r=digest_matches(io,KG_OTA_APP_BASE,&s.manifest);if(r!=KG_OTA_OK)return r;
    }
    if(!kg_ota_vectors_valid(io,KG_OTA_APP_BASE,s.manifest.length))return KG_OTA_VECTOR;
    return mark(io,H_DONE);
}
