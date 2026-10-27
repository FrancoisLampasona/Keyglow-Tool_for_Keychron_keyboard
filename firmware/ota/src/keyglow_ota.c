/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota.h"
#include "keyglow_ota_auth.h"
#include "sha256.h"
#include <string.h>

enum { H_SEAL=68, H_READY=72, H_COMMIT=76, H_DONE=80, H_INSTALL_STARTED=84,
       H_SOURCE_LENGTH=88, H_SOURCE_DIGEST=92, H_BITMAP=128,
       H_NONCE=176, H_KEY_ID=192, H_TAG=208, H_REPLACE=240 };
#define SEALED UINT32_C(0xa71a0a7a)
#define MARK UINT32_C(0xfffffffe)
static const uint8_t magic[8]={'K','G','O','T','A','0','0','1'};
static const uint8_t auth_magic[8]={'K','G','O','T','A','0','0','2'};
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
static uint32_t header_crc(const uint8_t h[KG_OTA_HEADER_SIZE],bool authenticated) {
    if(!authenticated)return kg_ota_crc32(h,64);
    uint8_t immutable[165];memcpy(immutable,h,64);
    memcpy(immutable+64,h+H_SOURCE_LENGTH,36);memcpy(immutable+100,h+H_NONCE,65);
    return kg_ota_crc32(immutable,sizeof immutable);
}
static void read_auth(const uint8_t h[KG_OTA_HEADER_SIZE],const kg_ota_manifest *m,kg_ota_authorization *a) {
    memset(a,0,sizeof *a);a->manifest=*m;a->source_length=le(h+H_SOURCE_LENGTH);
    memcpy(a->source_sha256,h+H_SOURCE_DIGEST,32);memcpy(a->nonce,h+H_NONCE,16);
    memcpy(a->key_id,h+H_KEY_ID,16);memcpy(a->tag,h+H_TAG,32);a->replace=h[H_REPLACE]!=0;
}
kg_ota_result kg_ota_inspect(const kg_ota_io *io,kg_ota_status *s) {
    uint8_t h[KG_OTA_HEADER_SIZE];
    if(!s)return KG_OTA_BOUNDS;
    if(!read_at(io,KG_OTA_STAGE_BASE,h,sizeof h))return KG_OTA_IO;
    memset(s,0,sizeof *s);
    bool authenticated=!memcmp(h,auth_magic,8)&&le(h+8)==2;
    if((!authenticated&&(memcmp(h,magic,8)||le(h+8)!=1))||le(h+28)!=KG_OTA_CHUNK_SIZE||le(h+H_SEAL)!=SEALED||le(h+64)!=header_crc(h,authenticated))return KG_OTA_NO_SESSION;
    s->authenticated=authenticated;
    s->manifest.target=le(h+12);s->manifest.address=le(h+16);s->manifest.length=le(h+20);s->manifest.build=le(h+24);memcpy(s->manifest.sha256,h+32,32);
    kg_ota_result r=valid_manifest(&s->manifest);if(r!=KG_OTA_OK)return r;
    /* Unknown/torn state markers fail closed rather than implying readiness. */
    for(unsigned i=H_READY;i<=(authenticated?H_INSTALL_STARTED:H_DONE);i+=4)if(le(h+i)!=UINT32_MAX&&le(h+i)!=MARK)return KG_OTA_CONFLICT;
    s->ready=le(h+H_READY)==MARK;s->committed=le(h+H_COMMIT)==MARK;s->installed=le(h+H_DONE)==MARK;
    s->install_started=authenticated&&le(h+H_INSTALL_STARTED)==MARK;
    if((s->committed&&!s->ready)||(s->installed&&!s->committed))return KG_OTA_CONFLICT;
    if(authenticated&&(h[H_REPLACE]>1||le(h+H_SOURCE_LENGTH)<8||le(h+H_SOURCE_LENGTH)>KG_OTA_APP_MAX||
       (s->install_started&&!s->committed)||(s->installed&&!s->install_started)))return KG_OTA_CONFLICT;
    memcpy(s->missing,h+H_BITMAP,KG_OTA_BITMAP_BYTES);
    return KG_OTA_OK;
}
kg_ota_result kg_ota_begin(const kg_ota_io *io,const kg_ota_manifest *m,bool replace) {
    kg_ota_result r=valid_manifest(m);if(r!=KG_OTA_OK)return r;
    kg_ota_status s;r=kg_ota_inspect(io,&s);
    if(r==KG_OTA_IO)return r;
    if(r==KG_OTA_OK) {
        if(s.authenticated)return KG_OTA_AUTH_ERROR;
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
kg_ota_result kg_ota_application_sha256(const kg_ota_io *io,uint32_t length,uint8_t digest[32]) {
    if(!digest||length<8||length>KG_OTA_APP_MAX)return KG_OTA_BOUNDS;
    kg_sha sha;kg_sha_init(&sha);uint8_t bytes[KG_OTA_CHUNK_SIZE];uint32_t offset=0;
    while(offset<length){size_t n=length-offset;if(n>sizeof bytes)n=sizeof bytes;
        if(!read_at(io,KG_OTA_APP_BASE+offset,bytes,n))return KG_OTA_IO;
        kg_sha_update(&sha,bytes,n);offset+=(uint32_t)n;}
    kg_sha_final(&sha,digest);return KG_OTA_OK;
}
kg_ota_result kg_ota_check_authorization(const kg_ota_io *io,const uint8_t key[32]) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(!s.authenticated)return KG_OTA_AUTH_ERROR;
    uint8_t h[KG_OTA_HEADER_SIZE];if(!read_at(io,KG_OTA_STAGE_BASE,h,sizeof h))return KG_OTA_IO;
    kg_ota_authorization a;read_auth(h,&s.manifest,&a);
    return kg_ota_auth_valid(key,&a)?KG_OTA_OK:KG_OTA_AUTH_ERROR;
}
kg_ota_result kg_ota_begin_authenticated(const kg_ota_io *io,const uint8_t key[32],const kg_ota_authorization *a) {
    if(!kg_ota_auth_valid(key,a))return KG_OTA_AUTH_ERROR;
    kg_ota_result r=valid_manifest(&a->manifest);if(r!=KG_OTA_OK)return r;
    kg_ota_status s;r=kg_ota_inspect(io,&s);if(r==KG_OTA_IO)return r;
    if(r==KG_OTA_OK){
        if(s.committed&&!s.installed){
            if(s.authenticated&&!a->replace&&same(&a->manifest,&s.manifest))return kg_ota_check_authorization(io,key);
            return KG_OTA_COMMIT_PENDING;
        }
        if(!a->replace&&!same(&a->manifest,&s.manifest))return KG_OTA_CONFLICT;
        if(!s.authenticated&&!a->replace)return KG_OTA_AUTH_ERROR;
        if(s.authenticated&&same(&a->manifest,&s.manifest)&&s.installed)
            return kg_ota_check_authorization(io,key);
    }else if(r!=KG_OTA_NO_SESSION)return r;
    uint8_t source_digest[32];kg_ota_result digest_result=kg_ota_application_sha256(io,a->source_length,source_digest);
    if(digest_result!=KG_OTA_OK)return digest_result;
    if(memcmp(source_digest,a->source_sha256,32))return KG_OTA_SOURCE_ERROR;
    if(r==KG_OTA_OK&&s.authenticated&&!a->replace)return kg_ota_check_authorization(io,key);
    if(!io->erase_sector||!io->erase_sector(io->context,5))return KG_OTA_IO;
    uint8_t h[KG_OTA_HEADER_SIZE];
    for(uint32_t address=KG_OTA_STAGE_BASE;address<KG_OTA_FLASH_END;address+=sizeof h){
        if(!read_at(io,address,h,sizeof h))return KG_OTA_IO;
        for(unsigned i=0;i<sizeof h;i++)if(h[i]!=255)return KG_OTA_IO;
    }
    memset(h,255,sizeof h);memcpy(h,auth_magic,8);put(h+8,2);put(h+12,a->manifest.target);
    put(h+16,a->manifest.address);put(h+20,a->manifest.length);put(h+24,a->manifest.build);
    put(h+28,KG_OTA_CHUNK_SIZE);memcpy(h+32,a->manifest.sha256,32);
    put(h+H_SOURCE_LENGTH,a->source_length);memcpy(h+H_SOURCE_DIGEST,a->source_sha256,32);
    memcpy(h+H_NONCE,a->nonce,16);memcpy(h+H_KEY_ID,a->key_id,16);memcpy(h+H_TAG,a->tag,32);h[H_REPLACE]=a->replace?1:0;
    put(h+64,header_crc(h,true));
    /* All immutable authentication bytes precede the final seal. Unsealed
     * interrupted metadata is never an authorized installation. */
    for(unsigned i=0;i<sizeof h;i+=4)if(i!=H_SEAL){r=program(io,KG_OTA_STAGE_BASE+i,le(h+i));if(r!=KG_OTA_OK)return r;}
    return program(io,KG_OTA_STAGE_BASE+H_SEAL,SEALED);
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
kg_ota_result kg_ota_copy_start(const kg_ota_io *io,uint32_t destination,uint32_t source,uint32_t length,kg_ota_copy_cursor *cursor) {
    if(!cursor)return KG_OTA_BOUNDS;
    memset(cursor,0,sizeof *cursor);
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    /* Subtraction bounds avoid wrapped end addresses. A source may be
     * unaligned, but can never expose loader keys, EEPROM, or staging. */
    if(!length||length>KG_OTA_COPY_MAX||destination%KG_OTA_CHUNK_SIZE||
       destination>=s.manifest.length||length>s.manifest.length-destination||
       source>=KG_OTA_APP_MAX||length>KG_OTA_APP_MAX-source||
       (length%KG_OTA_CHUNK_SIZE&&length!=s.manifest.length-destination))return KG_OTA_BOUNDS;
    cursor->manifest=s.manifest;cursor->destination=destination;cursor->source=source;cursor->remaining=length;
    return KG_OTA_OK;
}
kg_ota_result kg_ota_copy_step(const kg_ota_io *io,kg_ota_copy_cursor *cursor,bool *complete) {
    if(complete)*complete=false;
    if(!cursor||!complete)return KG_OTA_BOUNDS;
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(!same(&cursor->manifest,&s.manifest))return KG_OTA_CONFLICT;
    if(!cursor->remaining){*complete=true;return KG_OTA_OK;}
    /* Validate even a caller-provided or corrupted cursor before any read. */
    if(cursor->remaining>KG_OTA_COPY_MAX||cursor->destination%KG_OTA_CHUNK_SIZE||
       cursor->destination>=s.manifest.length||cursor->remaining>s.manifest.length-cursor->destination||
       cursor->source>=KG_OTA_APP_MAX||cursor->remaining>KG_OTA_APP_MAX-cursor->source||
       (cursor->remaining%KG_OTA_CHUNK_SIZE&&cursor->remaining!=s.manifest.length-cursor->destination))return KG_OTA_BOUNDS;
    uint8_t bytes[KG_OTA_CHUNK_SIZE];uint32_t n=cursor->remaining;
    if(n>sizeof bytes)n=sizeof bytes;
    if(!read_at(io,KG_OTA_APP_BASE+cursor->source,bytes,n))return KG_OTA_IO;
    r=kg_ota_chunk(io,cursor->destination,bytes,n);if(r!=KG_OTA_OK)return r;
    cursor->source+=n;cursor->destination+=n;cursor->remaining-=n;
    *complete=cursor->remaining==0;return KG_OTA_OK;
}
kg_ota_result kg_ota_copy(const kg_ota_io *io,uint32_t destination,uint32_t source,uint32_t length) {
    kg_ota_copy_cursor cursor;kg_ota_result r=kg_ota_copy_start(io,destination,source,length,&cursor);
    if(r!=KG_OTA_OK)return r;
    bool complete=false;
    while(!complete){r=kg_ota_copy_step(io,&cursor,&complete);if(r!=KG_OTA_OK)return r;}
    return KG_OTA_OK;
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
static kg_ota_result install_verified(const kg_ota_io *io,const kg_ota_status *status) {
    kg_ota_status s=*status;kg_ota_result r;
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
kg_ota_result kg_ota_install(const kg_ota_io *io) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    if(s.authenticated)return KG_OTA_AUTH_ERROR;
    return install_verified(io,&s);
}
kg_ota_result kg_ota_install_authenticated(const kg_ota_io *io,const uint8_t key[32]) {
    kg_ota_status s;kg_ota_result r=kg_ota_inspect(io,&s);if(r!=KG_OTA_OK)return r;
    r=kg_ota_check_authorization(io,key);if(r!=KG_OTA_OK)return r;
    if(!s.committed)return KG_OTA_NOT_READY;
    r=verify_stage(io,&s);if(r!=KG_OTA_OK)return r;
    if(!s.install_started){
        uint8_t h[KG_OTA_HEADER_SIZE],digest[32];if(!read_at(io,KG_OTA_STAGE_BASE,h,sizeof h))return KG_OTA_IO;
        r=kg_ota_application_sha256(io,le(h+H_SOURCE_LENGTH),digest);if(r!=KG_OTA_OK)return r;
        if(memcmp(digest,h+H_SOURCE_DIGEST,32))return KG_OTA_SOURCE_ERROR;
        /* This durable checkpoint is written only after MAC, complete target
         * digest/vectors and old application identity pass. Once set, a partial
         * erase need not reproduce the old application to resume installation. */
        r=mark(io,H_INSTALL_STARTED);if(r!=KG_OTA_OK)return r;
        s.install_started=true;
    }
    return install_verified(io,&s);
}
