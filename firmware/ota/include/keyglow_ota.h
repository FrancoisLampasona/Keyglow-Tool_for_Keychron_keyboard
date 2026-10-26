/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGLOW_OTA_H
#define KEYGLOW_OTA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Q6 Max ISO only. Addresses are absolute; erase callback takes sector number. */
#define KG_OTA_TARGET UINT32_C(0x08613434)
#define KG_OTA_FLASH_BASE UINT32_C(0x08000000)
#define KG_OTA_APP_BASE UINT32_C(0x08008000)
#define KG_OTA_APP_MAX UINT32_C(0x00018000)
#define KG_OTA_STAGE_BASE UINT32_C(0x08020000)
#define KG_OTA_FLASH_END UINT32_C(0x08040000)
#define KG_OTA_HEADER_SIZE 256u
#define KG_OTA_CHUNK_SIZE 256u
#define KG_OTA_MAX_CHUNKS 384u
#define KG_OTA_BITMAP_BYTES 48u

typedef enum {
    KG_OTA_OK = 0, KG_OTA_IO, KG_OTA_NO_SESSION, KG_OTA_TARGET_ERROR,
    KG_OTA_BOUNDS, KG_OTA_CONFLICT, KG_OTA_INCOMPLETE, KG_OTA_DIGEST,
    KG_OTA_VECTOR, KG_OTA_COMMIT_PENDING, KG_OTA_NOT_READY
} kg_ota_result;

typedef struct {
    void *context;
    bool (*read)(void *, uint32_t address, void *destination, size_t length);
    /* Program an aligned little-endian word. Only 1 -> 0 transitions permitted. */
    bool (*program_word)(void *, uint32_t address, uint32_t word);
    bool (*erase_sector)(void *, unsigned sector);
} kg_ota_io;

typedef struct {
    uint32_t target, address, length, build;
    uint8_t sha256[32];
} kg_ota_manifest;

typedef struct {
    kg_ota_manifest manifest;
    uint8_t missing[KG_OTA_BITMAP_BYTES]; /* Set bit = chunk still missing. */
    bool ready, committed, installed;
} kg_ota_status;

/* No allocation, clocks, transport, reset, or key-report side effects. */
kg_ota_result kg_ota_inspect(const kg_ota_io *, kg_ota_status *);
/* replace=false resumes an identical manifest. replace=true erases/restarts
 * an uncommitted session, even if identical; never replaces pending commit.
 * An identical already-installed image returns OK without erasing. */
kg_ota_result kg_ota_begin(const kg_ota_io *, const kg_ota_manifest *, bool replace);
kg_ota_result kg_ota_chunk(const kg_ota_io *, uint32_t offset, const uint8_t *, size_t);
kg_ota_result kg_ota_finish(const kg_ota_io *);
kg_ota_result kg_ota_commit(const kg_ota_io *);
/* Loader only, called before the application. Repeats safely after interruption.
 * NO_SESSION / NOT_READY means no committed update; do not treat IO as bootable.
 * OK means a committed image has been installed and verified. */
kg_ota_result kg_ota_install(const kg_ota_io *);
bool kg_ota_vectors_valid(const kg_ota_io *, uint32_t storage, uint32_t image_length);
uint32_t kg_ota_crc32(const void *, size_t);
void kg_ota_sha256(const void *, size_t, uint8_t digest[32]);
#endif
