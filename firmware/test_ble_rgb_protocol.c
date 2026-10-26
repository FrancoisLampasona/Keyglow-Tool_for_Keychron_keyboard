/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "ble_rgb_protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

static const uint8_t red[11] = {0x4b,0x52,0x47,0x42,0x01,0x01,0x00,0xff,0xff,0xe3,0xc0};
static const uint8_t off[11] = {0x4b,0x52,0x47,0x42,0x01,0x02,0x00,0x00,0x00,0x65,0x13};
static const uint8_t sample[11] = {0x4b,0x52,0x47,0x42,0x01,0x01,0x55,0xc0,0x80,0xcc,0x2d};
/* Independently generated with Python binascii.crc_hqx, not this decoder. */
static const uint8_t v2_red[13] = {0x4b,0x52,0x47,0x42,0x02,0x03,0x01,0x00,0xff,0xff,0x7f,0xa2,0x1a};
static const uint8_t v2_sample[13] = {0x4b,0x52,0x47,0x42,0x02,0x03,0x14,0x55,0xc0,0x80,0xc8,0x6a,0xa6};
static const uint8_t v2_off[13] = {0x4b,0x52,0x47,0x42,0x02,0x03,0x00,0x00,0x00,0x00,0x00,0x4b,0xaf};
static const uint8_t v2_max[13] = {0x4b,0x52,0x47,0x42,0x02,0x03,0x16,0xff,0xff,0xff,0xff,0x1b,0xbf};

typedef struct {
    ble_rgb_decoder_t decoder;
    ble_rgb_command_t command;
    uint32_t now;
    uint8_t clock;
    unsigned applied;
} harness_t;

static void harness_init(harness_t *h, uint32_t now, uint8_t initial_mask, bool arm) {
    memset(h, 0, sizeof(*h));
    h->now = now;
    ble_rgb_init(&h->decoder);
    if (arm) ble_rgb_arm(&h->decoder, now, initial_mask);
    /* Sender baseline. It can create an extra zero symbol if the old strobe was 1. */
    h->now += 80;
    if (ble_rgb_feed(&h->decoder, h->now, initial_mask & 0xf8u, &h->command)) ++h->applied;
}

static void symbol(harness_t *h, uint8_t data, bool duplicate_callback) {
    h->clock ^= 1u;
    uint8_t mask = (uint8_t)((h->clock << 2) | (data & 3u));
    h->now += 80;
    if (ble_rgb_feed(&h->decoder, h->now, mask, &h->command)) ++h->applied;
    if (duplicate_callback) {
        h->now += 1;
        CHECK(!ble_rgb_feed(&h->decoder, h->now, mask, &h->command));
    }
}

static void bytes(harness_t *h, const uint8_t *frame, size_t length, bool duplicates) {
    for (size_t i = 0; i < length; ++i) {
        for (int shift = 6; shift >= 0; shift -= 2) symbol(h, (uint8_t)(frame[i] >> shift), duplicates);
    }
}

static void update_crc(uint8_t *frame, size_t length) {
    uint16_t crc = ble_rgb_crc16(frame, length - 2u);
    frame[length - 2u] = (uint8_t)(crc >> 8);
    frame[length - 1u] = (uint8_t)crc;
}

static void test_v2(void) {
    CHECK(ble_rgb_crc16(v2_red, 11) == 0xa21a);
    CHECK(ble_rgb_crc16(v2_sample, 11) == 0x6aa6);
    CHECK(ble_rgb_crc16(v2_off, 11) == 0x4baf);
    CHECK(ble_rgb_crc16(v2_max, 11) == 0x1bbf);
    harness_t h;
    for (unsigned initial = 0; initial < 256; ++initial) {
        harness_init(&h, 100, (uint8_t)initial, true);
        bytes(&h, v2_sample, sizeof(v2_sample), true);
        CHECK(h.applied == 1 && !h.decoder.armed);
        CHECK(h.command.version == 2 && h.command.command == BLE_RGB_CMD_STATE && h.command.mode == 20);
        CHECK(h.command.hue == 85 && h.command.saturation == 192 && h.command.value == 128 && h.command.speed == 200);
        bytes(&h, v2_red, sizeof(v2_red), false);
        CHECK(h.applied == 1);
    }
    harness_init(&h, 0, 0, false);
    bytes(&h, v2_red, sizeof(v2_red), false);
    CHECK(h.applied == 0);
    harness_init(&h, 0, 0, true);
    bytes(&h, v2_off, sizeof(v2_off), false);
    CHECK(h.applied == 1 && h.command.mode == 0);
    harness_init(&h, 0, 0, true);
    bytes(&h, v2_max, sizeof(v2_max), false);
    CHECK(h.applied == 1 && h.command.mode == 22 && h.command.speed == 255);

    /* Every supported mode and speed boundary; all bytes of HSV are full range. */
    for (unsigned mode = 1; mode <= BLE_RGB_MODE_MAX; ++mode) {
        for (unsigned speed = 0; speed <= 255; ++speed) {
            uint8_t frame[13]; memcpy(frame, v2_sample, sizeof(frame));
            frame[6] = (uint8_t)mode;
            frame[7] = (uint8_t)speed;
            frame[8] = (uint8_t)(255u - speed);
            frame[9] = (uint8_t)speed;
            frame[10] = (uint8_t)speed;
            update_crc(frame, sizeof(frame));
            harness_init(&h, 0, 0, true);
            bytes(&h, frame, sizeof(frame), false);
            CHECK(h.applied == 1 && h.command.mode == mode && h.command.speed == speed);
            CHECK(h.command.hue == speed && h.command.saturation == 255u - speed && h.command.value == speed);
        }
    }

    for (unsigned bit = 0; bit < 104; ++bit) {
        uint8_t corrupted[13]; memcpy(corrupted, v2_sample, sizeof(corrupted));
        corrupted[bit / 8] ^= (uint8_t)(1u << (bit % 8));
        harness_init(&h, 0, 0, true);
        bytes(&h, corrupted, sizeof(corrupted), false);
        CHECK(h.applied == 0 && h.decoder.armed);
        h.now += 400; ble_rgb_tick(&h.decoder, h.now);
        bytes(&h, v2_sample, sizeof(v2_sample), false);
        CHECK(h.applied == 1);
    }
    /* CRC-valid unsupported effect, command, version and noncanonical OFF. */
    for (unsigned mode = 23; mode < 256; ++mode) {
        uint8_t frame[13]; memcpy(frame, v2_sample, sizeof(frame));
        frame[6] = (uint8_t)mode;
        update_crc(frame, sizeof(frame));
        harness_init(&h, 0, 0, true);
        bytes(&h, frame, sizeof(frame), false);
        CHECK(h.applied == 0 && h.decoder.armed);
        bytes(&h, v2_red, sizeof(v2_red), false);
        CHECK(h.applied == 1); /* immediate recovery after a complete rejected frame */
    }
    for (unsigned field = 4; field <= 10; ++field) {
        if (field == 6) continue;
        uint8_t frame[13]; memcpy(frame, v2_off, sizeof(frame));
        frame[field] = field == 4 ? 0x7f : (field == 5 ? 1 : 0xff);
        update_crc(frame, sizeof(frame));
        harness_init(&h, 0, 0, true);
        bytes(&h, frame, sizeof(frame), false);
        CHECK(h.applied == 0 && h.decoder.armed);
    }

    /* Every possible symbol-boundary truncation must leave no partial effects. */
    for (unsigned count = 0; count < 52; ++count) {
        harness_init(&h, 0, 0, true);
        for (unsigned i = 0; i < count; ++i) symbol(&h, (uint8_t)(v2_sample[i / 4] >> (6 - 2 * (i % 4))), false);
        CHECK(h.applied == 0);
        h.now += BLE_RGB_SYMBOL_TIMEOUT_MS;
        ble_rgb_tick(&h.decoder, h.now);
        CHECK(h.decoder.armed && !h.decoder.collecting);
        bytes(&h, v2_red, sizeof(v2_red), false);
        CHECK(h.applied == 1);
    }
    for (unsigned dropped = 0; dropped < 52; ++dropped) {
        harness_init(&h, 0, 0, true);
        for (unsigned i = 0; i < 52; ++i) {
            if (i == dropped) { h.clock ^= 1u; h.now += 80; continue; }
            symbol(&h, (uint8_t)(v2_sample[i / 4] >> (6 - 2 * (i % 4))), false);
        }
        CHECK(h.applied == 0);
    }
    /* Literal magic inside payload must not reset a valid in-progress frame. */
    uint8_t embedded[13]; memcpy(embedded, v2_red, sizeof(embedded));
    memcpy(embedded + 7, "KRGB", 4);
    update_crc(embedded, sizeof(embedded));
    harness_init(&h, 0, 0, true);
    bytes(&h, embedded, sizeof(embedded), false);
    CHECK(h.applied == 1 && h.command.hue == 'K' && h.command.speed == 'B');
    harness_init(&h, UINT32_MAX - 2000u, 0, true);
    bytes(&h, v2_sample, sizeof(v2_sample), false);
    CHECK(h.applied == 1);

    /* An in-flight valid frame cannot extend the absolute physical arm window. */
    harness_init(&h, 0, 0, true);
    h.now = BLE_RGB_ARM_MS - 1000u;
    bytes(&h, v2_red, sizeof(v2_red), false);
    CHECK(h.applied == 0 && !h.decoder.armed);
}

static void test_v3(void) {
    harness_t h;
    uint8_t frame[13]; memcpy(frame, v2_sample, sizeof(frame)); frame[4] = 3;
    for (unsigned command = BLE_RGB_CMD_STATE; command <= BLE_RGB_CMD_SAVE_STATE; ++command) {
        frame[5] = (uint8_t)command; update_crc(frame, sizeof(frame));
        for (unsigned initial=0; initial<256; ++initial) {
            harness_init(&h, 0, (uint8_t)initial, false);
            bytes(&h, frame, sizeof(frame), true);
            CHECK(h.applied == 1 && h.command.version == 3 && h.command.command == command);
            CHECK(!h.decoder.armed && h.command.hue == 85 && h.command.speed == 200);
            bytes(&h, frame, sizeof(frame), false); CHECK(h.applied == 2); /* no re-arm */
        }
        for (unsigned bit=0; bit<104; ++bit) {
            uint8_t corrupted[13]; memcpy(corrupted,frame,sizeof(frame));
            corrupted[bit/8] ^= (uint8_t)(1u<<(bit%8));
            harness_init(&h,0,0,false); bytes(&h,corrupted,sizeof(corrupted),false);
            CHECK(h.applied == 0);
            h.now += BLE_RGB_SYMBOL_TIMEOUT_MS; ble_rgb_tick(&h.decoder,h.now);
            bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 1);
        }
    }
    for (unsigned count=0; count<52; ++count) {
        harness_init(&h,0,0,false);
        for (unsigned i=0;i<count;++i) symbol(&h,(uint8_t)(frame[i/4]>>(6-2*(i%4))),false);
        CHECK(h.applied == 0);
        h.now += BLE_RGB_SYMBOL_TIMEOUT_MS; ble_rgb_tick(&h.decoder,h.now);
        CHECK(!ble_rgb_receiving(&h.decoder));
        bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 1);
    }
    for (unsigned mode=0;mode<256;++mode) {
        uint8_t candidate[13]; memcpy(candidate,frame,sizeof(frame)); candidate[6]=(uint8_t)mode;
        if (mode==0) memset(candidate+7,0,4);
        update_crc(candidate,sizeof(candidate));
        harness_init(&h,0,0,false); bytes(&h,candidate,sizeof(candidate),false);
        CHECK(h.applied == (mode<=BLE_RGB_MODE_MAX ? 1u : 0u));
    }
    for (unsigned command=0;command<256;++command) {
        frame[5]=(uint8_t)command; update_crc(frame,sizeof(frame));
        harness_init(&h,0,0,false); bytes(&h,frame,sizeof(frame),false);
        CHECK(h.applied == ((command==3 || command==4) ? 1u : 0u));
    }
    frame[5]=4; frame[6]=0; /* noncanonical OFF */
    update_crc(frame,sizeof(frame)); harness_init(&h,0,0,false);
    bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 0);
    memset(frame+7,0,4); update_crc(frame,sizeof(frame));
    bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 1 && h.command.mode == 0);
    /* Legacy traffic and ordinary lock changes cannot apply or persist v3. */
    harness_init(&h,0,0,false);
    bytes(&h,v2_sample,sizeof(v2_sample),false); bytes(&h,red,sizeof(red),false);
    for (unsigned i=0;i<10000;++i) {
        h.now += 10; CHECK(!ble_rgb_feed(&h.decoder,h.now,(uint8_t)(i%8),&h.command));
    }
    CHECK(h.applied == 0);
    /* Disarm/transport reset discards an in-progress packet. */
    harness_init(&h,0,0,false); bytes(&h,frame,8,false); ble_rgb_disarm(&h.decoder);
    bytes(&h,frame+8,5,false); CHECK(h.applied == 0);
    h.now += 400; ble_rgb_tick(&h.decoder,h.now);
    bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 1);
    harness_init(&h,UINT32_MAX-2000u,0,false); bytes(&h,frame,sizeof(frame),false); CHECK(h.applied == 1);
    puts("PASS: automatic v3 preview/save, 256 initial masks, repeat frames, 208 corruptions, truncation/resync, strict modes/commands/OFF, legacy isolation, ordinary lock noise, abort and rollover.");
}

int main(void) {
    CHECK(ble_rgb_crc16((const uint8_t *)"123456789", 9) == 0x29b1);
    CHECK(ble_rgb_crc16(red, 9) == 0xe3c0);
    CHECK(ble_rgb_crc16(sample, 9) == 0xcc2d);
    CHECK(ble_rgb_crc16(off, 9) == 0x6513);

    harness_t h;
    for (uint8_t initial = 0; initial < 32; ++initial) {
        harness_init(&h, 100, initial, true);
        bytes(&h, sample, 11, true);
        CHECK(h.applied == 1 && !h.decoder.armed);
        CHECK(h.command.command == 1 && h.command.hue == 85 &&
              h.command.saturation == 192 && h.command.value == 128);
        bytes(&h, red, 11, false);
        CHECK(h.applied == 1); /* one-shot */
    }

    harness_init(&h, 0, 0, false);
    bytes(&h, red, 11, false);
    CHECK(h.applied == 0); /* cannot arm via host traffic */

    harness_init(&h, 0, 0, true);
    bytes(&h, off, 11, false);
    CHECK(h.applied == 1 && h.command.command == BLE_RGB_CMD_OFF);
    ble_rgb_arm(&h.decoder, h.now, (uint8_t)(h.clock << 2));
    bytes(&h, red, 11, false);
    CHECK(h.applied == 2 && h.command.command == BLE_RGB_CMD_STATIC);

    /* Every single-bit corruption, including magic/header/payload/CRC, rejected. */
    for (unsigned bit = 0; bit < 88; ++bit) {
        uint8_t corrupted[11]; memcpy(corrupted, red, 11);
        corrupted[bit / 8] ^= (uint8_t)(1u << (bit % 8));
        harness_init(&h, 0, 0, true);
        bytes(&h, corrupted, 11, false);
        CHECK(h.applied == 0 && h.decoder.armed);
        h.now += 400; ble_rgb_tick(&h.decoder, h.now);
        bytes(&h, red, 11, false);
        CHECK(h.applied == 1); /* recover while still armed */
    }

    /* Correct CRC cannot make an unsupported version, command or OFF payload valid. */
    for (unsigned kind = 0; kind < 3; ++kind) {
        uint8_t invalid[11]; memcpy(invalid, off, 11);
        if (kind == 0) invalid[4] = 2;
        if (kind == 1) invalid[5] = 3;
        if (kind == 2) invalid[6] = 1;
        update_crc(invalid, sizeof(invalid));
        harness_init(&h, 0, 0, true);
        bytes(&h, invalid, 11, false);
        CHECK(h.applied == 0);
    }

    harness_init(&h, 0, 0, true);
    bytes(&h, red, 7, false);
    h.now += 400; ble_rgb_tick(&h.decoder, h.now);
    CHECK(h.decoder.armed && !h.decoder.collecting);
    bytes(&h, red + 7, 4, false);
    CHECK(h.applied == 0);
    bytes(&h, red, 11, false);
    CHECK(h.applied == 1);

    /* Missing one symbol corrupts alignment and must not partially apply a frame. */
    harness_init(&h, 0, 0, true);
    for (unsigned i = 0; i < 44; ++i) {
        if (i == 23) { h.clock ^= 1u; h.now += 80; continue; }
        symbol(&h, (uint8_t)(red[i / 4] >> (6 - 2 * (i % 4))), false);
    }
    CHECK(h.applied == 0);

    /* Common Caps/Num/Scroll activity must not match the frame. */
    harness_init(&h, 0, 0, true);
    for (unsigned i = 0; i < 200; ++i) {
        h.now += 10;
        CHECK(!ble_rgb_feed(&h.decoder, h.now, (uint8_t)(i % 8), &h.command));
    }
    CHECK(h.applied == 0 && h.decoder.armed);

    /* Expiration is absolute, even while symbols continue arriving. */
    harness_init(&h, 500, 0, true);
    ble_rgb_tick(&h.decoder, 30499); CHECK(h.decoder.armed);
    ble_rgb_tick(&h.decoder, 30500); CHECK(!h.decoder.armed);
    h.now = 30500;
    ble_rgb_arm(&h.decoder, h.now, (uint8_t)(h.clock << 2));
    bytes(&h, sample, 11, false);
    CHECK(h.applied == 1);

    harness_init(&h, UINT32_MAX - 2000u, 0, true);
    bytes(&h, red, 11, false);
    CHECK(h.applied == 1); /* uint32 timestamp rollover */

    harness_init(&h, 0, 0, true);
    ble_rgb_disarm(&h.decoder);
    bytes(&h, red, 11, false);
    CHECK(h.applied == 0);

    test_v2();
    test_v3();
    puts("PASS: v1 compatibility; v2 CRC vectors, 256 initial LED masks, 22 modes x 256 speeds/HSV, one-shot, 192 bit corruptions, invalid effects/frames, all symbol truncations/drops, recovery, timeout, expiry and timer rollover.");
    return 0;
}
