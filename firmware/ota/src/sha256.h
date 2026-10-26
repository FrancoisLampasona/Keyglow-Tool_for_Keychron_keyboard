/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KG_SHA256_H
#define KG_SHA256_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint32_t h[8]; uint64_t bytes; uint8_t block[64]; size_t used; } kg_sha;
void kg_sha_init(kg_sha *);
void kg_sha_update(kg_sha *, const void *, size_t);
void kg_sha_final(kg_sha *, uint8_t [32]);
#endif
