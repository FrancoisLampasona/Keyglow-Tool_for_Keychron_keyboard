/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "ble_rgb_protocol.h"
#include <string.h>

#define BLE_RGB_MAGIC UINT32_C(0x4b524742)

uint16_t ble_rgb_crc16(const uint8_t *bytes, size_t length) {
    uint16_t crc = UINT16_C(0xffff);
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)((uint16_t)bytes[i] << 8);
        for (uint8_t bit = 0; bit < 8; ++bit) {
            crc = (uint16_t)((crc & UINT16_C(0x8000))
                                ? (uint16_t)(crc << 1) ^ UINT16_C(0x1021)
                                : (uint16_t)(crc << 1));
        }
    }
    return crc;
}

static void reset_parser(ble_rgb_decoder_t *decoder) {
    decoder->collecting = false;
    decoder->magic_window = 0;
    decoder->magic_symbols = 0;
    decoder->frame_index = 0;
    decoder->frame_size = 0;
    decoder->byte_symbols = 0;
    decoder->byte_accumulator = 0;
}

void ble_rgb_init(ble_rgb_decoder_t *decoder) {
    memset(decoder, 0, sizeof(*decoder));
}

void ble_rgb_disarm(ble_rgb_decoder_t *decoder) {
    decoder->armed = false;
    decoder->has_symbol = false;
    reset_parser(decoder);
}

void ble_rgb_arm(ble_rgb_decoder_t *decoder, uint32_t now_ms, uint8_t current_led_mask) {
    ble_rgb_init(decoder);
    decoder->armed = true;
    decoder->armed_at = now_ms;
    decoder->last_symbol_at = now_ms;
    decoder->last_clock = (uint8_t)((current_led_mask >> 2) & 1u);
}

void ble_rgb_tick(ble_rgb_decoder_t *decoder, uint32_t now_ms) {
    /* Unsigned subtraction also handles a single uint32 timer rollover. */
    if (decoder->armed && (uint32_t)(now_ms - decoder->armed_at) >= BLE_RGB_ARM_MS) {
        ble_rgb_disarm(decoder);
    } else if (decoder->has_symbol &&
               (uint32_t)(now_ms - decoder->last_symbol_at) >= BLE_RGB_SYMBOL_TIMEOUT_MS) {
        reset_parser(decoder);
        decoder->has_symbol = false;
    }
}

static bool valid_frame(const uint8_t *frame, uint8_t frame_size) {
    if (frame[4] == 1u) {
        if (frame_size != BLE_RGB_V1_FRAME_SIZE) return false;
        if (frame[5] != BLE_RGB_CMD_STATIC && frame[5] != BLE_RGB_CMD_OFF) return false;
        if (frame[5] == BLE_RGB_CMD_OFF && (frame[6] || frame[7] || frame[8])) return false;
    } else if (frame[4] == 2u || frame[4] == 3u) {
        if (frame_size != BLE_RGB_V2_FRAME_SIZE) return false;
        if (frame[5] != BLE_RGB_CMD_STATE && !(frame[4] == 3u && frame[5] == BLE_RGB_CMD_SAVE_STATE)) return false;
        if (frame[6] > BLE_RGB_MODE_MAX) return false;
        /* OFF has a single canonical representation, including speed. */
        if (frame[6] == 0u && (frame[7] || frame[8] || frame[9] || frame[10])) return false;
    } else {
        return false;
    }
    const uint8_t crc_offset = (uint8_t)(frame_size - 2u);
    const uint16_t received_crc = (uint16_t)((uint16_t)frame[crc_offset] << 8) | frame[crc_offset + 1u];
    return received_crc == ble_rgb_crc16(frame, crc_offset);
}

bool ble_rgb_feed(ble_rgb_decoder_t *decoder, uint32_t now_ms,
                  uint8_t led_mask, ble_rgb_command_t *command) {
    ble_rgb_tick(decoder, now_ms);
    if (command == NULL) return false;

    uint8_t clock = (uint8_t)((led_mask >> 2) & 1u);
    if (clock == decoder->last_clock) return false;
    decoder->last_clock = clock;
    decoder->last_symbol_at = now_ms;
    decoder->has_symbol = true;
    uint8_t symbol = led_mask & 3u;

    if (!decoder->collecting) {
        decoder->magic_window = (decoder->magic_window << 2) | symbol;
        if (decoder->magic_symbols < 16u) ++decoder->magic_symbols;
        if (decoder->magic_symbols == 16u && decoder->magic_window == BLE_RGB_MAGIC) {
            decoder->frame[0] = 0x4b;
            decoder->frame[1] = 0x52;
            decoder->frame[2] = 0x47;
            decoder->frame[3] = 0x42;
            decoder->frame_index = 4;
            decoder->byte_symbols = 0;
            decoder->byte_accumulator = 0;
            decoder->collecting = true;
        }
        return false;
    }

    decoder->byte_accumulator = (uint8_t)((decoder->byte_accumulator << 2) | symbol);
    if (++decoder->byte_symbols != 4u) return false;
    decoder->frame[decoder->frame_index++] = decoder->byte_accumulator;
    decoder->byte_accumulator = 0;
    decoder->byte_symbols = 0;
    if (decoder->frame_index == 5u) {
        if (decoder->frame[4] == 1u && decoder->armed) decoder->frame_size = BLE_RGB_V1_FRAME_SIZE;
        else if (decoder->frame[4] == 2u && decoder->armed) decoder->frame_size = BLE_RGB_V2_FRAME_SIZE;
        else if (decoder->frame[4] == 3u) decoder->frame_size = BLE_RGB_V3_FRAME_SIZE;
        else { reset_parser(decoder); return false; }
    }
    if (decoder->frame_index != decoder->frame_size) return false;

    if (!valid_frame(decoder->frame, decoder->frame_size)) {
        reset_parser(decoder);
        return false;
    }
    command->version = decoder->frame[4];
    command->command = decoder->frame[5];
    if (command->version == 1u) {
        command->mode = command->command == BLE_RGB_CMD_OFF ? 0u : 1u;
        command->hue = decoder->frame[6];
        command->saturation = decoder->frame[7];
        command->value = decoder->frame[8];
        command->speed = 0; /* v1 does not change speed. */
    } else {
        command->mode = decoder->frame[6];
        command->hue = decoder->frame[7];
        command->saturation = decoder->frame[8];
        command->value = decoder->frame[9];
        command->speed = decoder->frame[10];
    }
    ble_rgb_disarm(decoder);
    return true;
}

/* Only a matching prefix (at least one complete byte) or a full magic frame
 * suppresses indicator overlays. Ordinary lock traffic is not a receive mode. */
bool ble_rgb_receiving(const ble_rgb_decoder_t *decoder) {
    if (decoder->collecting) return true;
    for (uint8_t symbols = 4; symbols < 16 && symbols <= decoder->magic_symbols; ++symbols) {
        const uint32_t mask = (UINT32_C(1) << (symbols * 2u)) - 1u;
        if ((decoder->magic_window & mask) == (BLE_RGB_MAGIC >> (32u - symbols * 2u))) return true;
    }
    return false;
}
