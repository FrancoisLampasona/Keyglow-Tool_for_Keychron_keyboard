/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ble_wire.h"
#include "vectors.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr, "wire line %d: %s\n", __LINE__, #value); exit(1); } } while (0)
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void put32(uint8_t *p, uint32_t v) { for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (8 * i)); }

static kg_ble_event feed(kg_ble_led_decoder *d, const uint8_t *frame, size_t size, uint32_t *now, uint32_t interval) {
    kg_ble_event last = KG_BLE_NONE;
    *now += interval;
    (void)kg_ble_led_feed(d, *now, 0); /* baseline, also resynchronizes clock after cancellation */
    for (size_t i = 0; i < size * 4u; ++i) {
        *now += interval;
        const uint8_t symbol = (uint8_t)(((i & 1u) ? 0u : 4u) | ((frame[i / 4u] >> (6u - 2u * (i % 4u))) & 3u));
        last = kg_ble_led_feed(d, *now, symbol);
    }
    return last;
}

int main(void) {
    CHECK(kg_ble_crc32((const uint8_t *)"123456789", 9) == UINT32_C(0xcbf43926));
    CHECK(kg_ble_crc16((const uint8_t *)"123456789", 9) == UINT16_C(0x29b1));
    uint8_t encoded[KG_BLE_REQUEST_MAX], taken[KG_BLE_REQUEST_MAX], report[8]; size_t size = 0;
    const wire_vector *maximum = NULL, *commit = NULL, *receipt = NULL;
    for (size_t v = 0; v < WIRE_VECTOR_COUNT; ++v) {
        const wire_vector *vector = &wire_vectors[v];
        if (!strcmp(vector->name, "request-data-max")) maximum = vector;
        if (!strcmp(vector->name, "ack-commit")) commit = vector;
        if (!strcmp(vector->name, "request-receipt")) receipt = vector;
        if (vector->kind == 1) {
            CHECK(kg_ble_request_valid(vector->bytes, vector->size));
            CHECK(kg_ble_request_encode(vector->bytes[5], le32(vector->bytes + 8), vector->bytes + 12, vector->size - 16, encoded, sizeof encoded, &size));
            CHECK(size == vector->size && !memcmp(encoded, vector->bytes, size));
            for (size_t i = 0; i <= size * 4; ++i) {
                uint8_t mask = 255; CHECK(kg_ble_request_led_mask(encoded, size, i, &mask));
                CHECK(mask <= 7 && (i == 0 ? mask == 0 : (mask & 4) == ((i & 1) ? 4 : 0)));
            }
            for (unsigned initial = 0; initial < 8; ++initial) {
                kg_ble_led_decoder d; kg_ble_led_init(&d, (uint8_t)initial);
                uint32_t now = initial & 1u ? UINT32_MAX - 400 : 100;
                CHECK(feed(&d, encoded, size, &now, 20) == KG_BLE_FRAME_READY);
                CHECK(d.ready && kg_ble_led_tick(&d, now + 1000) == KG_BLE_FRAME_READY);
                CHECK(kg_ble_led_feed(&d, now + 1001, 4) == KG_BLE_BACKPRESSURE);
                CHECK(!kg_ble_led_take(&d, taken, size - 1, &size) && d.ready);
                CHECK(kg_ble_led_take(&d, taken, sizeof taken, &size));
                CHECK(size == vector->size && !memcmp(taken, vector->bytes, size));
                CHECK(!kg_ble_led_take(&d, taken, sizeof taken, &size));
                size = vector->size;
            }
        } else {
            CHECK(kg_ble_ack_valid(vector->bytes, vector->size));
            CHECK(kg_ble_ack_encode(vector->bytes[5], le32(vector->bytes + 6), vector->bytes[10], vector->bytes[11], vector->bytes + 13, vector->size - 15, encoded, sizeof encoded, &size));
            CHECK(size == vector->size && !memcmp(encoded, vector->bytes, size));
            memset(taken, 0, sizeof taken);
            for (size_t i = 0; i < size * 2; ++i) {
                CHECK(kg_ble_ack_report(encoded, size, i, report));
                for (unsigned j = 0; j < 8; ++j) if (j != 1) CHECK(report[j] == 0);
                CHECK((report[1] & 0xf0u) == ((i & 1u) ? 0x90u : 0x80u));
                taken[i / 2] = (uint8_t)((taken[i / 2] << 4) | (report[1] & 15));
            }
            CHECK(!memcmp(taken, encoded, size));
            CHECK(kg_ble_ack_report(encoded, size, size * 2, report));
            for (unsigned j = 0; j < 8; ++j) CHECK(report[j] == 0);
            CHECK(!kg_ble_ack_report(encoded, size, size * 2 + 1, report));
        }
    }
    CHECK(maximum && commit && receipt);
    /* Every one-bit corruption of a maximum request must remain unqueued. */
    for (size_t bit = 0; bit < maximum->size * 8; ++bit) {
        memcpy(encoded, maximum->bytes, maximum->size); encoded[bit / 8] ^= (uint8_t)(1u << (bit % 8));
        CHECK(!kg_ble_request_valid(encoded, maximum->size));
        kg_ble_led_decoder d; kg_ble_led_init(&d, 0); uint32_t now = 100;
        (void)feed(&d, encoded, maximum->size, &now, 20); CHECK(!d.ready);
    }
    /* Reordered bytes and missing/reordered symbol edges cannot enqueue data.
     * Repeated identical LED notifications are harmless and deliberately ignored. */
    for (size_t index = 12; index + 1 < maximum->size; ++index) {
        if (maximum->bytes[index] == maximum->bytes[index + 1]) continue;
        memcpy(encoded, maximum->bytes, maximum->size);
        encoded[index] = maximum->bytes[index + 1]; encoded[index + 1] = maximum->bytes[index];
        kg_ble_led_decoder corrupt; kg_ble_led_init(&corrupt, 0); uint32_t clock = 0;
        (void)feed(&corrupt, encoded, maximum->size, &clock, 20); CHECK(!corrupt.ready);
    }
    for (unsigned mutation = 0; mutation < 3; ++mutation) {
        kg_ble_led_decoder corrupt; kg_ble_led_init(&corrupt, 0); uint32_t clock = 0;
        for (size_t index = 0; index <= maximum->size * 4; ++index) {
            uint8_t mask; CHECK(kg_ble_request_led_mask(maximum->bytes, maximum->size, index, &mask));
            if (mutation == 0 && index == 80) continue;
            if (mutation == 1 && (index == 80 || index == 81)) {
                CHECK(kg_ble_request_led_mask(maximum->bytes, maximum->size, index == 80 ? 81 : 80, &mask));
            }
            clock += 20; (void)kg_ble_led_feed(&corrupt, clock, mask);
            if (mutation == 2 && !corrupt.ready) (void)kg_ble_led_feed(&corrupt, clock + 1, mask);
        }
        CHECK(corrupt.ready == (mutation == 2));
    }
    /* Truncation at every byte, timeout, then a clean frame (including magic in its payload). */
    for (size_t cut = 1; cut < maximum->size; ++cut) {
        kg_ble_led_decoder d; kg_ble_led_init(&d, 0); uint32_t now = 100;
        (void)feed(&d, maximum->bytes, cut, &now, 20); CHECK(!d.ready);
        now += KG_BLE_LED_TIMEOUT_MS; CHECK(kg_ble_led_tick(&d, now) == KG_BLE_TIMEOUT);
        CHECK(feed(&d, maximum->bytes, maximum->size, &now, 20) == KG_BLE_FRAME_READY);
    }
    kg_ble_led_decoder d; kg_ble_led_init(&d, 0); uint32_t now = 100;
    const uint8_t rgb[] = {'K','R','G','B',3,3,1,2,3,4,5,6,7};
    (void)feed(&d, rgb, sizeof rgb, &now, 80); CHECK(!d.ready);
    CHECK(feed(&d, maximum->bytes, maximum->size, &now, 80) == KG_BLE_FRAME_READY);
    kg_ble_led_cancel(&d, 0); CHECK(!d.ready && !d.collecting);
    (void)feed(&d, maximum->bytes, 24, &now, 20);
    (void)feed(&d, rgb, sizeof rgb, &now, 20); CHECK(!d.ready);
    now += 400; (void)kg_ble_led_tick(&d, now);
    CHECK(feed(&d, maximum->bytes, maximum->size, &now, 20) == KG_BLE_FRAME_READY);
    kg_ble_led_cancel(&d, 0); now = 100;
    (void)feed(&d, maximum->bytes, maximum->size, &now, 399); CHECK(!d.ready); /* total-frame timeout */
    kg_ble_led_cancel(&d, 0); memcpy(encoded, maximum->bytes, maximum->size); encoded[6] = 255; encoded[7] = 255;
    (void)feed(&d, encoded, maximum->size, &now, 20); CHECK(!d.ready && d.size <= KG_BLE_REQUEST_MAX);
    CHECK(!kg_ble_request_encode(2, 1, encoded, 261, taken, sizeof taken, &size));
    CHECK(!kg_ble_request_encode(0, 1, NULL, 0, taken, sizeof taken, &size));
    CHECK(!kg_ble_ack_encode(0x7f, 1, 0, 0, NULL, 0, taken, sizeof taken, &size));
    CHECK(!kg_ble_ack_encode(3, 1, 0, 16, NULL, 0, taken, sizeof taken, &size));
    CHECK(!kg_ble_ack_encode(3, 1, 0, 0, encoded, 129, taken, sizeof taken, &size));
    uint8_t compact = 255;
    for (uint32_t r = 0; r <= 12; ++r) CHECK(kg_ble_compact_result(r, &compact) && compact == r);
    for (uint32_t r = 0x100; r <= 0x102; ++r) CHECK(kg_ble_compact_result(r, &compact) && compact == r - 0x80);
    CHECK(!kg_ble_compact_result(0x200, &compact)); CHECK(!kg_ble_compact_result(13, &compact));
    CHECK(!kg_ble_compact_result(UINT32_MAX, &compact));
    CHECK(kg_ble_reply_interval_allowed(100, 0));
    CHECK(!kg_ble_reply_interval_allowed(40, 0)); CHECK(!kg_ble_reply_interval_allowed(20, 0));
    CHECK(kg_ble_reply_interval_allowed(40, 1)); CHECK(kg_ble_reply_interval_allowed(20, 2));
    CHECK(!kg_ble_reply_interval_allowed(0, 3)); CHECK(!kg_ble_reply_interval_allowed(100, 4));
    CHECK(!kg_ble_reply_interval_allowed(40, 2)); CHECK(!kg_ble_reply_interval_allowed(20, 1));
    CHECK(kg_ble_ack_receipt_encode(commit->bytes, commit->size, encoded, sizeof encoded, &size));
    CHECK(size == receipt->size && !memcmp(encoded, receipt->bytes, size));
    CHECK(kg_ble_ack_receipt_matches(encoded, size, commit->bytes, commit->size));
    for (unsigned offset = 8; offset <= 14; ++offset) {
        memcpy(taken, encoded, size); taken[offset] ^= 1; put32(taken + size - 4, kg_ble_crc32(taken, size - 4));
        CHECK(!kg_ble_ack_receipt_matches(taken, size, commit->bytes, commit->size));
    }
    uint8_t legacy[120] = {'K','G','O','T',1,0x83,104};
    put32(legacy + 8, 123); put32(legacy + 12, 0x100); put32(legacy + 16, 15);
    for (unsigned i = 20; i < 116; ++i) legacy[i] = (uint8_t)i;
    put32(legacy + 116, kg_ble_crc32(legacy, 116));
    CHECK(kg_ble_ack_from_legacy(legacy, sizeof legacy, false, encoded, sizeof encoded, &size) && size == 15 && encoded[10] == 0x80);
    CHECK(kg_ble_ack_from_legacy(legacy, sizeof legacy, true, encoded, sizeof encoded, &size) && size == 111 && !memcmp(encoded + 13, legacy + 20, 96));
    put32(legacy + 12, 0x200); put32(legacy + 116, kg_ble_crc32(legacy, 116));
    CHECK(!kg_ble_ack_from_legacy(legacy, sizeof legacy, false, encoded, sizeof encoded, &size));
    printf("BLE OTA C wire: %u assertions passed; no hardware or flash API linked.\n", checks);
    return 0;
}
