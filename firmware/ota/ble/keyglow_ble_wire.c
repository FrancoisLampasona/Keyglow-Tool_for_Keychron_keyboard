/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "keyglow_ble_wire.h"
#include <string.h>

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static void put32(uint8_t *p, uint32_t value) { for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(value >> (8u * i)); }
static uint16_t be16(const uint8_t *p) { return (uint16_t)((uint16_t)p[0] << 8) | p[1]; }
static bool operation_valid(uint8_t op) { return op > 0 && op <= KG_BLE_ACK_RECEIPT_OP; }
static bool result_valid(uint8_t result) { return result <= 12u || (result >= 0x80u && result <= 0x82u); }

uint16_t kg_ble_crc16(const uint8_t *data, size_t length) {
    uint16_t crc = UINT16_C(0xffff);
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (uint8_t bit = 0; bit < 8; ++bit)
            crc = (uint16_t)((crc & UINT16_C(0x8000)) ? (uint16_t)(crc << 1) ^ UINT16_C(0x1021) : (uint16_t)(crc << 1));
    }
    return crc;
}
uint32_t kg_ble_crc32(const uint8_t *data, size_t length) {
    uint32_t crc = UINT32_C(0xffffffff);
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1u) ? UINT32_C(0xedb88320) : 0u);
    }
    return ~crc;
}

bool kg_ble_request_valid(const uint8_t *frame, size_t size) {
    if (!frame || size < 16u || size > KG_BLE_REQUEST_MAX || memcmp(frame, "KGOT", 4) || frame[4] != 1u || !operation_valid(frame[5])) return false;
    const size_t payload = (size_t)frame[6] | (size_t)frame[7] << 8;
    return payload + 16u == size && le32(frame + size - 4u) == kg_ble_crc32(frame, size - 4u);
}
bool kg_ble_request_encode(uint8_t operation, uint32_t request_id, const uint8_t *payload,
                           size_t payload_size, uint8_t *out, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!out || !written || !operation_valid(operation) || payload_size > KG_BLE_REQUEST_PAYLOAD_MAX ||
        (payload_size && !payload) || capacity < payload_size + 16u) return false;
    memcpy(out, "KGOT", 4); out[4] = 1; out[5] = operation;
    out[6] = (uint8_t)payload_size; out[7] = (uint8_t)(payload_size >> 8); put32(out + 8, request_id);
    if (payload_size) memcpy(out + 12, payload, payload_size);
    put32(out + 12 + payload_size, kg_ble_crc32(out, 12u + payload_size));
    *written = payload_size + 16u;
    return true;
}
bool kg_ble_request_led_mask(const uint8_t *frame, size_t size, size_t symbol_index, uint8_t *mask) {
    if (!mask || !kg_ble_request_valid(frame, size) || symbol_index > size * 4u) return false;
    if (symbol_index == 0) { *mask = 0; return true; }
    const size_t index = symbol_index - 1u;
    *mask = (uint8_t)(((index & 1u) ? 0u : 4u) | ((frame[index / 4u] >> (6u - 2u * (index % 4u))) & 3u));
    return true;
}

static void reset_parser(kg_ble_led_decoder *d) {
    d->collecting = false; d->has_symbol = false;
    d->magic_window = 0; d->magic_symbols = 0;
    d->byte_symbols = 0; d->accumulator = 0;
    d->size = 0; d->expected_size = 0;
}
void kg_ble_led_init(kg_ble_led_decoder *d, uint8_t current_led_mask) {
    memset(d, 0, sizeof(*d)); d->last_clock = (uint8_t)((current_led_mask >> 2) & 1u);
}
void kg_ble_led_cancel(kg_ble_led_decoder *d, uint8_t current_led_mask) { kg_ble_led_init(d, current_led_mask); }
kg_ble_event kg_ble_led_tick(kg_ble_led_decoder *d, uint32_t now) {
    if (d->ready) return KG_BLE_FRAME_READY;
    if ((d->has_symbol && (uint32_t)(now - d->last_symbol_at) >= KG_BLE_LED_TIMEOUT_MS) ||
        (d->collecting && (uint32_t)(now - d->frame_started_at) >= KG_BLE_FRAME_TIMEOUT_MS)) {
        reset_parser(d); return KG_BLE_TIMEOUT;
    }
    return KG_BLE_NONE;
}
kg_ble_event kg_ble_led_feed(kg_ble_led_decoder *d, uint32_t now, uint8_t led_mask) {
    if (d->ready) return KG_BLE_BACKPRESSURE;
    (void)kg_ble_led_tick(d, now);
    const uint8_t clock = (uint8_t)((led_mask >> 2) & 1u);
    if (clock == d->last_clock) return KG_BLE_NONE;
    d->last_clock = clock; d->last_symbol_at = now; d->has_symbol = true;
    const uint8_t symbol = led_mask & 3u;
    if (!d->collecting) {
        d->magic_window = (d->magic_window << 2) | symbol;
        if (d->magic_symbols < 16u) ++d->magic_symbols;
        if (d->magic_symbols == 16u && d->magic_window == UINT32_C(0x4b474f54)) {
            memcpy(d->frame, "KGOT", 4); d->size = 4;
            d->collecting = true; d->frame_started_at = now;
        }
        return KG_BLE_NONE;
    }
    d->accumulator = (uint8_t)((d->accumulator << 2) | symbol);
    if (++d->byte_symbols != 4u) return KG_BLE_NONE;
    if (d->size >= KG_BLE_REQUEST_MAX) { reset_parser(d); return KG_BLE_REJECTED; }
    d->frame[d->size++] = d->accumulator;
    d->byte_symbols = 0; d->accumulator = 0;
    if ((d->size == 5u && d->frame[4] != 1u) || (d->size == 6u && !operation_valid(d->frame[5]))) {
        reset_parser(d); return KG_BLE_REJECTED;
    }
    if (d->size == 8u) {
        const size_t payload = (size_t)d->frame[6] | (size_t)d->frame[7] << 8;
        if (payload > KG_BLE_REQUEST_PAYLOAD_MAX) { reset_parser(d); return KG_BLE_REJECTED; }
        d->expected_size = (uint16_t)(payload + 16u);
    }
    if (d->expected_size == 0u || d->size < d->expected_size) return KG_BLE_NONE;
    if (!kg_ble_request_valid(d->frame, d->size)) { reset_parser(d); return KG_BLE_REJECTED; }
    d->ready = true;
    return KG_BLE_FRAME_READY;
}
bool kg_ble_led_take(kg_ble_led_decoder *d, uint8_t *out, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!d->ready || !out || !written || capacity < d->size) return false;
    memcpy(out, d->frame, d->size); *written = d->size;
    d->ready = false; reset_parser(d);
    return true;
}

bool kg_ble_ack_valid(const uint8_t *frame, size_t size) {
    if (!frame || size < 15u || size > KG_BLE_ACK_MAX || memcmp(frame, "KGAK", 4) || frame[4] != 1u ||
        !operation_valid(frame[5]) || frame[5] == KG_BLE_ACK_RECEIPT_OP || !result_valid(frame[10]) ||
        (frame[11] & 0xf0u) || frame[12] > KG_BLE_ACK_PAYLOAD_MAX) return false;
    return (size_t)frame[12] + 15u == size && be16(frame + size - 2u) == kg_ble_crc16(frame, size - 2u);
}
bool kg_ble_ack_encode(uint8_t operation, uint32_t request_id, uint8_t result, uint8_t flags,
                      const uint8_t *payload, size_t payload_size, uint8_t *out, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!out || !written || !operation_valid(operation) || operation == KG_BLE_ACK_RECEIPT_OP || !result_valid(result) ||
        (flags & 0xf0u) || payload_size > KG_BLE_ACK_PAYLOAD_MAX || (payload_size && !payload) || capacity < payload_size + 15u) return false;
    memcpy(out, "KGAK", 4); out[4] = 1; out[5] = operation; put32(out + 6, request_id);
    out[10] = result; out[11] = flags; out[12] = (uint8_t)payload_size;
    if (payload_size) memcpy(out + 13, payload, payload_size);
    const uint16_t crc = kg_ble_crc16(out, 13u + payload_size);
    out[13 + payload_size] = (uint8_t)(crc >> 8); out[14 + payload_size] = (uint8_t)crc;
    *written = payload_size + 15u;
    return true;
}
bool kg_ble_compact_result(uint32_t engine_result, uint8_t *wire_result) {
    if (!wire_result) return false;
    if (engine_result <= 12u) { *wire_result = (uint8_t)engine_result; return true; }
    if (engine_result >= 0x100u && engine_result <= 0x102u) { *wire_result = (uint8_t)(0x80u + engine_result - 0x100u); return true; }
    return false;
}
bool kg_ble_ack_from_legacy(const uint8_t *legacy, size_t legacy_size, bool include_state,
                           uint8_t *out, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!legacy || legacy_size != 120u || memcmp(legacy, "KGOT", 4) || legacy[4] != 1u ||
        !(legacy[5] & 0x80u) || legacy[6] != 104u || legacy[7] != 0 ||
        le32(legacy + 116) != kg_ble_crc32(legacy, 116)) return false;
    uint8_t result;
    const uint32_t flags = le32(legacy + 16);
    if (!kg_ble_compact_result(le32(legacy + 12), &result) || flags > 15u) return false;
    return kg_ble_ack_encode(legacy[5] & 0x7fu, le32(legacy + 8), result, (uint8_t)flags,
                             include_state ? legacy + 20 : NULL, include_state ? 96u : 0u,
                             out, capacity, written);
}
bool kg_ble_ack_report(const uint8_t *ack, size_t size, size_t symbol_index, uint8_t report[8]) {
    if (!report) return false;
    memset(report, 0, 8);
    if (!kg_ble_ack_valid(ack, size) || symbol_index > size * 2u) return false;
    if (symbol_index == size * 2u) return true;
    const uint8_t value = ack[symbol_index / 2u];
    report[1] = (uint8_t)((symbol_index & 1u ? 0x90u : 0x80u) | ((symbol_index & 1u ? value : value >> 4) & 15u));
    return true;
}
bool kg_ble_reply_interval_allowed(uint16_t milliseconds, uint8_t calibrated_reply_rates) {
    if (calibrated_reply_rates & ~3u) return false;
    return milliseconds == KG_BLE_REPLY_DEFAULT_MS ||
           (milliseconds == 40u && (calibrated_reply_rates & KG_BLE_CALIBRATED_REPLY_40)) ||
           (milliseconds == 20u && (calibrated_reply_rates & KG_BLE_CALIBRATED_REPLY_20));
}
bool kg_ble_ack_receipt_encode(const uint8_t *ack, size_t ack_size, uint8_t *out, size_t capacity, size_t *written) {
    if (written) *written = 0;
    if (!kg_ble_ack_valid(ack, ack_size)) return false;
    const uint8_t payload[3] = {ack[5], ack[ack_size - 2u], ack[ack_size - 1u]};
    return kg_ble_request_encode(KG_BLE_ACK_RECEIPT_OP, le32(ack + 6), payload, sizeof(payload), out, capacity, written);
}
bool kg_ble_ack_receipt_matches(const uint8_t *request, size_t request_size, const uint8_t *pending_ack, size_t ack_size) {
    return kg_ble_request_valid(request, request_size) && request_size == 19u && request[5] == KG_BLE_ACK_RECEIPT_OP &&
           kg_ble_ack_valid(pending_ack, ack_size) && le32(request + 8) == le32(pending_ack + 6) &&
           request[12] == pending_ack[5] && request[13] == pending_ack[ack_size - 2u] && request[14] == pending_ack[ack_size - 1u];
}
