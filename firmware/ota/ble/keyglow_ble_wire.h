/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGLOW_BLE_WIRE_H
#define KEYGLOW_BLE_WIRE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KG_BLE_REQUEST_MAX 276u
#define KG_BLE_REQUEST_PAYLOAD_MAX 260u
#define KG_BLE_ACK_PAYLOAD_MAX 128u
#define KG_BLE_ACK_MAX (15u + KG_BLE_ACK_PAYLOAD_MAX)
#define KG_BLE_LED_TIMEOUT_MS 400u
#define KG_BLE_FRAME_TIMEOUT_MS 180000u
#define KG_BLE_ACK_RECEIPT_OP 0x7fu
#define KG_BLE_REPLY_DEFAULT_MS 100u
#define KG_BLE_CALIBRATED_REPLY_40 0x01u
#define KG_BLE_CALIBRATED_REPLY_20 0x02u

typedef enum { KG_BLE_NONE, KG_BLE_FRAME_READY, KG_BLE_REJECTED, KG_BLE_TIMEOUT, KG_BLE_BACKPRESSURE } kg_ble_event;

typedef struct {
    bool collecting, has_symbol, ready;
    uint8_t last_clock, magic_symbols, byte_symbols, accumulator;
    uint16_t size, expected_size;
    uint32_t magic_window, last_symbol_at, frame_started_at;
    uint8_t frame[KG_BLE_REQUEST_MAX];
} kg_ble_led_decoder;

uint16_t kg_ble_crc16(const uint8_t *data, size_t length);
uint32_t kg_ble_crc32(const uint8_t *data, size_t length);
/* Wire validity is not command support, authorization, flash safety or delivery. */
bool kg_ble_request_valid(const uint8_t *frame, size_t size);
bool kg_ble_request_encode(uint8_t operation, uint32_t request_id, const uint8_t *payload,
                           size_t payload_size, uint8_t *out, size_t capacity, size_t *written);
/* Index zero establishes clock low; subsequent masks carry two bits per edge.
 * The hardware sender must preserve other indicator bits and restore its snapshot. */
bool kg_ble_request_led_mask(const uint8_t *frame, size_t size, size_t symbol_index, uint8_t *mask);

void kg_ble_led_init(kg_ble_led_decoder *decoder, uint8_t current_led_mask);
void kg_ble_led_cancel(kg_ble_led_decoder *decoder, uint8_t current_led_mask);
kg_ble_event kg_ble_led_tick(kg_ble_led_decoder *decoder, uint32_t now_ms);
kg_ble_event kg_ble_led_feed(kg_ble_led_decoder *decoder, uint32_t now_ms, uint8_t led_mask);
/* One bounded mailbox. A small destination does not consume the ready frame. */
bool kg_ble_led_take(kg_ble_led_decoder *decoder, uint8_t *out, size_t capacity, size_t *written);

bool kg_ble_ack_valid(const uint8_t *frame, size_t size);
bool kg_ble_ack_encode(uint8_t operation, uint32_t request_id, uint8_t result, uint8_t flags,
                      const uint8_t *payload, size_t payload_size, uint8_t *out, size_t capacity, size_t *written);
/* Explicit mapping: core 0..12 unchanged; adapter 0x100..0x102 -> 0x80..0x82.
 * Unknown 32-bit results are rejected, never truncated to success. */
bool kg_ble_compact_result(uint32_t engine_result, uint8_t *wire_result);
bool kg_ble_ack_from_legacy(const uint8_t *legacy, size_t legacy_size, bool include_state,
                           uint8_t *out, size_t capacity, size_t *written);
/* Each result is exactly eight bytes with mods/keycodes zero. Index 2*size
 * produces the trailing all-zero report; larger indices are rejected. */
bool kg_ble_ack_report(const uint8_t *ack, size_t size, size_t symbol_index, uint8_t report[8]);
bool kg_ble_reply_interval_allowed(uint16_t milliseconds, uint8_t calibrated_reply_rates);

/* A receipt confirms this exact pending ACK, not merely that bytes were queued.
 * The caller still enforces session identity, authorization, expiry and commit
 * result before invoking its delivered callback. No engine call or reset here. */
bool kg_ble_ack_receipt_encode(const uint8_t *ack, size_t ack_size, uint8_t *out, size_t capacity, size_t *written);
bool kg_ble_ack_receipt_matches(const uint8_t *request, size_t request_size, const uint8_t *pending_ack, size_t ack_size);
#endif
