/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ota.h"
#include "keyglow_ota_wire.h"
#include "keyglow_ota_auth.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint8_t flash[256*1024],saved[256*1024],image[KG_OTA_APP_MAX];
static unsigned mutations,fail_at,fail_mode,protected_writes;
static const unsigned sectors[7]={0,16384,32768,49152,65536,131072,262144};
static void put(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static bool read_flash(void *c,uint32_t a,void *p,size_t n){(void)c;assert(a>=KG_OTA_FLASH_BASE&&a-KG_OTA_FLASH_BASE+n<=sizeof flash);memcpy(p,flash+(a-KG_OTA_FLASH_BASE),n);return true;}
/* program_word is implemented as four byte writes by the target driver.
 * Cut modes: before, after 1/2/3 bytes, after all 4, arbitrary alternating
 * programmed bits, and the complementary alternating programmed bits. */
static bool program_flash(void *c, uint32_t a, uint32_t v) {
    (void)c;
    assert(!(a & 3));
    if(a < KG_OTA_APP_BASE) protected_writes++;
    assert(a >= KG_OTA_APP_BASE && a < KG_OTA_FLASH_END);
    mutations++;
    bool cut = mutations == fail_at;
    uint8_t b[4];
    put(b, v);
    uint8_t *p = flash + (a - KG_OTA_FLASH_BASE);
    for(unsigned i = 0; i < 4; i++) assert((p[i] & b[i]) == b[i]);
    if(!cut || fail_mode == 4) {
        for(unsigned i = 0; i < 4; i++) p[i] &= b[i];
    } else if(fail_mode <= 3) {
        for(unsigned i = 0; i < fail_mode; i++) p[i] &= b[i];
    } else {
        uint8_t retained = fail_mode == 5 ? 0x55 : 0xaa;
        for(unsigned i = 0; i < 4; i++) p[i] &= (uint8_t)(b[i] | retained);
    }
    return !cut;
}
static bool erase_flash(void *c, unsigned s) {
    (void)c;
    if(s < 2) protected_writes++;
    assert(s >= 2 && s <= 5);
    mutations++;
    bool cut = mutations == fail_at;
    size_t n = sectors[s+1] - sectors[s];
    uint8_t *p = flash + sectors[s];
    if(!cut || fail_mode == 4) memset(p, 255, n);
    else if(fail_mode <= 3) memset(p, 255, n * fail_mode / 4);
    else {
        uint8_t erased = fail_mode == 5 ? 0x55 : 0xaa;
        for(size_t i = 0; i < n; i++) p[i] |= erased;
    }
    return !cut;
}
static const kg_ota_io io={NULL,read_flash,program_flash,erase_flash};
static void fresh(void){memset(flash,0x5a,sizeof flash);memset(flash+sectors[5],255,sectors[6]-sectors[5]);mutations=fail_at=protected_writes=0;}
static kg_ota_manifest manifest(unsigned length){for(unsigned i=0;i<length;i++)image[i]=(uint8_t)(i*31u+7u);put(image,0x20010000);put(image+4,KG_OTA_APP_BASE+9);kg_ota_manifest m={KG_OTA_TARGET,KG_OTA_APP_BASE,length,7,{0}};kg_ota_sha256(image,length,m.sha256);return m;}
static kg_ota_result receive(const kg_ota_manifest *m){kg_ota_result r=kg_ota_begin(&io,m,false);if(r)return r;for(unsigned off=0;off<m->length;off+=256){unsigned n=m->length-off;if(n>256)n=256;r=kg_ota_chunk(&io,off,image+off,n);if(r)return r;}r=kg_ota_finish(&io);if(r)return r;return kg_ota_commit(&io);}
static void hash_tests(void){uint8_t d[32];static const uint8_t expect[32]={0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};kg_ota_sha256("abc",3,d);assert(!memcmp(d,expect,32));assert(kg_ota_crc32("123456789",9)==0xcbf43926u);}
static void hash_long_tests(void) {
    const char *values[] = {"", "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"};
    const char *expected[] = {"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "6542c911659a61d36aba54ab933d8d5f4685cc15cb4a42d52d5acd02c87fa41b"};
    for(unsigned test=0;test<3;test++) {
        uint8_t digest[32],bytes[1031];char hex[65];
        if(test<2)kg_ota_sha256(values[test],strlen(values[test]),digest);
        else {for(unsigned i=0;i<sizeof bytes;i++)bytes[i]=(uint8_t)(i*31u+7u);kg_ota_sha256(bytes,sizeof bytes,digest);}
        for(unsigned i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
        assert(!strcmp(hex,expected[test]));
    }
}
static void receive_cuts(void){fresh();kg_ota_manifest m=manifest(1031);memcpy(saved,flash,sizeof flash);assert(receive(&m)==KG_OTA_OK);unsigned total=mutations;for(unsigned mode=0;mode<7;mode++)for(unsigned cut=1;cut<=total;cut++){memcpy(flash,saved,sizeof flash);mutations=0;fail_at=cut;fail_mode=mode;assert(receive(&m)==KG_OTA_IO);fail_at=0;assert(receive(&m)==KG_OTA_OK);assert(!memcmp(flash,saved,KG_OTA_STAGE_BASE-KG_OTA_FLASH_BASE));assert(kg_ota_install(&io)==KG_OTA_OK);assert(!memcmp(flash+(KG_OTA_APP_BASE-KG_OTA_FLASH_BASE),image,m.length));assert(!memcmp(flash,saved,KG_OTA_APP_BASE-KG_OTA_FLASH_BASE));assert(!protected_writes);}printf("Receiver: %u mutation points × 7 byte/bit interruption modes resumed\n",total);}
static void install_cuts(void){fresh();kg_ota_manifest m=manifest(1031);assert(receive(&m)==KG_OTA_OK);memcpy(saved,flash,sizeof flash);mutations=0;assert(kg_ota_install(&io)==KG_OTA_OK);unsigned total=mutations;for(unsigned mode=0;mode<7;mode++)for(unsigned cut=1;cut<=total;cut++){memcpy(flash,saved,sizeof flash);mutations=0;fail_at=cut;fail_mode=mode;assert(kg_ota_install(&io)==KG_OTA_IO);fail_at=0;assert(kg_ota_install(&io)==KG_OTA_OK);assert(!memcmp(flash+32768,image,m.length));assert(!memcmp(flash,saved,32768));assert(!memcmp(flash+131072+256,saved+131072+256,sizeof flash-131072-256));unsigned writes=mutations;assert(kg_ota_install(&io)==KG_OTA_OK);assert(writes==mutations);assert(!protected_writes);}printf("Installer: %u mutation points × 7 byte/bit interruption modes resumed\n",total);}
static void rejects(void){fresh();kg_ota_manifest m=manifest(513),bad=m;bad.target++;assert(kg_ota_begin(&io,&bad,false)==KG_OTA_TARGET_ERROR);bad=m;bad.length=KG_OTA_APP_MAX+1;assert(kg_ota_begin(&io,&bad,false)==KG_OTA_BOUNDS);bad=m;bad.address--;assert(kg_ota_begin(&io,&bad,false)==KG_OTA_BOUNDS);assert(!mutations);assert(kg_ota_begin(&io,&m,false)==KG_OTA_OK);assert(kg_ota_commit(&io)==KG_OTA_NOT_READY);assert(kg_ota_finish(&io)==KG_OTA_INCOMPLETE);assert(kg_ota_chunk(&io,UINT32_MAX,image,256)==KG_OTA_BOUNDS);assert(kg_ota_chunk(&io,1,image,256)==KG_OTA_BOUNDS);assert(kg_ota_chunk(&io,512,image,2)==KG_OTA_BOUNDS);assert(kg_ota_chunk(&io,0,image,256)==KG_OTA_OK);unsigned before=mutations;assert(kg_ota_chunk(&io,0,image,256)==KG_OTA_OK);assert(before==mutations);uint8_t conflict[256];memcpy(conflict,image,256);conflict[20]^=1;assert(kg_ota_chunk(&io,0,conflict,256)==KG_OTA_CONFLICT);assert(receive(&m)==KG_OTA_OK);bad=m;bad.build++;assert(kg_ota_begin(&io,&bad,true)==KG_OTA_COMMIT_PENDING);flash[131072+256+100]^=1;before=mutations;assert(kg_ota_install(&io)==KG_OTA_DIGEST);assert(before==mutations);fresh();m=manifest(513);put(image+4,0x08000009);kg_ota_sha256(image,m.length,m.sha256);assert(kg_ota_begin(&io,&m,false)==KG_OTA_OK);for(unsigned off=0;off<m.length;off+=256){unsigned n=m.length-off;if(n>256)n=256;assert(kg_ota_chunk(&io,off,image+off,n)==KG_OTA_OK);}assert(kg_ota_finish(&io)==KG_OTA_VECTOR);assert(!protected_writes);puts("Bounds, target, digest, vectors, commit barrier, duplicate/conflict checks passed");}
static void explicit_restart_after_bad_chunk(void) {
    fresh();
    kg_ota_manifest m = manifest(513);
    assert(kg_ota_begin(&io, &m, false) == KG_OTA_OK);

    /* A transport-valid DATA frame may still contain the wrong image bytes. */
    uint8_t request[KG_OTA_FRAME_MAX] = {'K','G','O','T',1,KG_OTA_DATA};
    uint8_t reply[KG_OTA_REPLY_SIZE];
    size_t reply_length;
    request[6] = 4; request[7] = 1; /* 260-byte payload */
    put(request + 8, 7);
    put(request + 12, 0);
    memcpy(request + 16, image, 256);
    request[16 + 20] ^= 1;
    put(request + 272, kg_ota_crc32(request, 272));
    assert(kg_ota_handle_frame(&io, request, sizeof request, reply, sizeof reply, &reply_length));
    assert(reply_length == sizeof reply && reply[12] == KG_OTA_OK);
    assert(kg_ota_chunk(&io, 256, image + 256, 256) == KG_OTA_OK);
    assert(kg_ota_chunk(&io, 512, image + 512, 1) == KG_OTA_OK);
    assert(kg_ota_finish(&io) == KG_OTA_DIGEST);
    assert(kg_ota_chunk(&io, 0, image, 256) == KG_OTA_CONFLICT);

    unsigned before = mutations;
    memcpy(saved, flash, sizeof flash);
    assert(kg_ota_begin(&io, &m, false) == KG_OTA_OK);
    assert(mutations == before && !memcmp(saved, flash, sizeof flash));
    assert(kg_ota_begin(&io, &m, true) == KG_OTA_OK);
    assert(mutations > before);
    assert(!memcmp(saved, flash, KG_OTA_STAGE_BASE - KG_OTA_FLASH_BASE));
    kg_ota_status status;
    assert(kg_ota_inspect(&io, &status) == KG_OTA_OK);
    assert(!status.ready && !status.committed && !status.installed);
    assert((status.missing[0] & 7) == 7);
    assert(receive(&m) == KG_OTA_OK);

    before = mutations;
    memcpy(saved, flash, sizeof flash);
    assert(kg_ota_begin(&io, &m, true) == KG_OTA_COMMIT_PENDING);
    assert(kg_ota_begin(&io, &m, false) == KG_OTA_OK);
    assert(mutations == before && !memcmp(saved, flash, sizeof flash));
    assert(kg_ota_install(&io) == KG_OTA_OK);
    assert(!memcmp(flash + (KG_OTA_APP_BASE - KG_OTA_FLASH_BASE), image, m.length));
    before = mutations;
    assert(kg_ota_begin(&io, &m, true) == KG_OTA_OK);
    assert(mutations == before && !protected_writes);
    puts("CRC-valid wrong chunk: digest rejected, explicit restart recovered; pending commit preserved");
}
static void maximum(void){fresh();kg_ota_manifest m=manifest(KG_OTA_APP_MAX);assert(receive(&m)==KG_OTA_OK);assert(kg_ota_install(&io)==KG_OTA_OK);assert(!memcmp(flash+32768,image,m.length));assert(!protected_writes);puts("Full 96 KiB image installed; sectors 0/1 untouched");}
static void wire_tests(void){fresh();uint8_t request[16]={ 'K','G','O','T',1,KG_OTA_STATUS,0,0,7,0,0,0 },reply[120];size_t length;put(request+12,kg_ota_crc32(request,12));assert(kg_ota_handle_frame(&io,request,sizeof request,reply,sizeof reply,&length));assert(length==120&&reply[5]==(KG_OTA_STATUS|0x80)&&reply[8]==7&&reply[12]==KG_OTA_NO_SESSION);for(unsigned i=0;i<16;i++){request[i]^=1;assert(!kg_ota_handle_frame(&io,request,sizeof request,reply,sizeof reply,&length));request[i]^=1;}assert(!kg_ota_handle_frame(&io,request,sizeof request,reply,119,&length));assert(!mutations);memcpy(reply,request,16);assert(kg_ota_handle_frame(&io,reply,16,reply,sizeof reply,&length));assert(reply[8]==7);puts("Wire CRC, sizes, request correlation, no-write rejection passed");}
static uint8_t test_key[32]; /* Published deterministic fixture, never a device key. */
static void sign_authorization(kg_ota_authorization *a){
    uint8_t digest[32],payload[149],message[136];
    kg_ota_sha256(test_key,sizeof test_key,digest);memcpy(a->key_id,digest,16);
    assert(kg_ota_auth_encode(a,payload));memcpy(message,KG_OTA_AUTH_DOMAIN,19);memcpy(message+19,payload,117);
    kg_ota_hmac_sha256(test_key,message,sizeof message,a->tag);
}
static kg_ota_authorization authorization(const kg_ota_manifest *m){
    kg_ota_authorization a={0};a.manifest=*m;a.source_length=1031;
    assert(kg_ota_application_sha256(&io,a.source_length,a.source_sha256)==KG_OTA_OK);
    for(unsigned i=0;i<16;i++)a.nonce[i]=(uint8_t)(0xa0+i);
    sign_authorization(&a);return a;
}
static void hex_equal(const uint8_t *bytes,size_t size,const char *expected){char hex[129];assert(size<=64);for(size_t i=0;i<size;i++)snprintf(hex+2*i,3,"%02x",bytes[i]);assert(!strcmp(hex,expected));}
static void authentication_vectors(void){
    for(unsigned i=0;i<32;i++)test_key[i]=(uint8_t)(i+1);
    kg_ota_authorization a={0};a.manifest=(kg_ota_manifest){KG_OTA_TARGET,KG_OTA_APP_BASE,513,0x01020304,{0}};
    a.source_length=1024;kg_ota_sha256("keyglow synthetic target",24,a.manifest.sha256);
    kg_ota_sha256("keyglow synthetic baseline",26,a.source_sha256);
    for(unsigned i=0;i<16;i++)a.nonce[i]=(uint8_t)(0xa0+i);
    sign_authorization(&a);
    hex_equal(a.key_id,16,"ae216c2ef5247a3782c135efa279a3e4");
    hex_equal(a.tag,32,"d4f5e0aaee3ab706a6ee1aa1183e18167f115ec20ae22e26f1b71174df57224c");
    assert(kg_ota_auth_valid(test_key,&a));
    uint8_t payload[149];assert(kg_ota_auth_encode(&a,payload));kg_ota_authorization decoded;
    for(unsigned i=0;i<149;i++){payload[i]^=1;assert(kg_ota_auth_decode(payload,&decoded));assert(!kg_ota_auth_valid(test_key,&decoded));payload[i]^=1;}
    payload[116]=2;assert(!kg_ota_auth_decode(payload,&decoded));payload[116]=0;
    uint8_t blank[32]={0};assert(!kg_ota_auth_valid(blank,&a));memset(blank,255,32);assert(!kg_ota_auth_valid(blank,&a));
    fresh();uint8_t *slot=flash+(KG_OTA_KEY_SLOT-KG_OTA_FLASH_BASE);memset(slot,255,64);
    assert(!kg_ota_read_device_key(&io,blank));for(unsigned i=0;i<32;i++)assert(!blank[i]);
    memcpy(slot,"KGKY0001",8);memcpy(slot+8,test_key,32);memcpy(slot+40,a.key_id,16);put(slot+56,kg_ota_crc32(slot,56));
    assert(kg_ota_crc32(slot,56)==0x9687bdeeu);assert(kg_ota_read_device_key(&io,blank)&&!memcmp(blank,test_key,32));
    for(unsigned i=0;i<64;i++){slot[i]^=1;assert(!kg_ota_read_device_key(&io,blank));slot[i]^=1;}
    puts("HMAC: independent host vector, all149 authorization bytes, blank key and all64 key-slot corruption cases passed");
}
static kg_ota_result receive_authenticated(const kg_ota_authorization *a){
    kg_ota_result r=kg_ota_begin_authenticated(&io,test_key,a);if(r)return r;
    for(unsigned offset=0;offset<a->manifest.length;offset+=256){size_t n=a->manifest.length-offset;if(n>256)n=256;r=kg_ota_chunk(&io,offset,image+offset,n);if(r)return r;}
    r=kg_ota_finish(&io);return r==KG_OTA_OK?kg_ota_commit(&io):r;
}
static void authentication_rejections(void){
    fresh();kg_ota_manifest m=manifest(1031);kg_ota_authorization a=authorization(&m),bad=a;
    bad.tag[0]^=1;assert(kg_ota_begin_authenticated(&io,test_key,&bad)==KG_OTA_AUTH_ERROR);assert(!mutations);
    bad=a;bad.source_sha256[0]^=1;sign_authorization(&bad);assert(kg_ota_begin_authenticated(&io,test_key,&bad)==KG_OTA_SOURCE_ERROR);assert(!mutations);
    assert(receive_authenticated(&a)==KG_OTA_OK);kg_ota_status status;assert(kg_ota_inspect(&io,&status)==KG_OTA_OK&&status.authenticated&&!status.install_started);
    unsigned before=mutations;assert(kg_ota_begin(&io,&m,true)==KG_OTA_AUTH_ERROR);assert(kg_ota_install(&io)==KG_OTA_AUTH_ERROR);assert(mutations==before);
    a.replace=true;sign_authorization(&a);assert(kg_ota_begin_authenticated(&io,test_key,&a)==KG_OTA_COMMIT_PENDING);assert(mutations==before);
    flash[KG_OTA_APP_BASE-KG_OTA_FLASH_BASE+10]^=1;
    assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_SOURCE_ERROR);assert(mutations==before);
    flash[KG_OTA_APP_BASE-KG_OTA_FLASH_BASE+10]^=1;
    uint8_t wrong[32];memcpy(wrong,test_key,32);wrong[0]^=1;
    assert(kg_ota_install_authenticated(&io,wrong)==KG_OTA_AUTH_ERROR);assert(mutations==before);
    assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_OK);
    assert(kg_ota_inspect(&io,&status)==KG_OTA_OK&&status.install_started&&status.installed);
    fresh();m=manifest(1031);assert(receive(&m)==KG_OTA_OK);before=mutations;
    assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_AUTH_ERROR);assert(before==mutations);
    puts("HMAC: source binding, pending commit, wrong key and unsigned-format rejection before application erase passed");
}
static void authenticated_cuts(void){
    fresh();kg_ota_manifest m=manifest(1031);kg_ota_authorization a=authorization(&m);memcpy(saved,flash,sizeof flash);
    assert(receive_authenticated(&a)==KG_OTA_OK);unsigned total=mutations;
    for(unsigned mode=0;mode<7;mode++)for(unsigned cut=1;cut<=total;cut++){
        memcpy(flash,saved,sizeof flash);mutations=0;fail_at=cut;fail_mode=mode;
        assert(receive_authenticated(&a)==KG_OTA_IO);fail_at=0;
        assert(receive_authenticated(&a)==KG_OTA_OK);assert(!memcmp(flash,saved,KG_OTA_STAGE_BASE-KG_OTA_FLASH_BASE));
        assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_OK);assert(!memcmp(flash+32768,image,m.length));assert(!protected_writes);
    }
    printf("Authenticated receiver: %u mutation points ×7 interruption modes resumed\n",total);
    fresh();m=manifest(1031);a=authorization(&m);assert(receive_authenticated(&a)==KG_OTA_OK);memcpy(saved,flash,sizeof flash);mutations=0;
    assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_OK);total=mutations;
    for(unsigned mode=0;mode<7;mode++)for(unsigned cut=1;cut<=total;cut++){
        memcpy(flash,saved,sizeof flash);mutations=0;fail_at=cut;fail_mode=mode;
        assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_IO);fail_at=0;
        assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_OK);
        assert(!memcmp(flash+32768,image,m.length)&&!memcmp(flash,saved,32768));
        unsigned before=mutations;assert(kg_ota_install_authenticated(&io,test_key)==KG_OTA_OK);assert(before==mutations&&!protected_writes);
    }
    printf("Authenticated installer: %u mutation points ×7 interruption modes resumed, including source-check checkpoint\n",total);
}
int main(void){hash_tests();hash_long_tests();receive_cuts();install_cuts();rejects();explicit_restart_after_bad_chunk();maximum();wire_tests();authentication_vectors();authentication_rejections();authenticated_cuts();puts("All OTA simulation tests passed (no hardware operations)");return 0;}
