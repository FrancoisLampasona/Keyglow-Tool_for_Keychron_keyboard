/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLE_RGB_PROTOCOL_H
#define BLE_RGB_PROTOCOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define BLE_RGB_V1_FRAME_SIZE 11u
#define BLE_RGB_V2_FRAME_SIZE 13u
#define BLE_RGB_V3_FRAME_SIZE 13u
#define BLE_RGB_FRAME_SIZE BLE_RGB_V3_FRAME_SIZE
#define BLE_RGB_ARM_MS 30000u
#define BLE_RGB_SYMBOL_TIMEOUT_MS 400u
#define BLE_RGB_CMD_STATIC 1u
#define BLE_RGB_CMD_OFF 2u
#define BLE_RGB_CMD_STATE 3u
#define BLE_RGB_CMD_SAVE_STATE 4u
#define BLE_RGB_MODE_MAX 22u

typedef struct {
    uint8_t version;
    uint8_t command;
    uint8_t mode;
    uint8_t hue;
    uint8_t saturation;
    uint8_t value;
    uint8_t speed;
} ble_rgb_command_t;

typedef struct {
    bool armed;
    bool collecting;
    bool has_symbol;
    uint8_t last_clock;
    uint8_t magic_symbols;
    uint8_t frame_index;
    uint8_t frame_size;
    uint8_t byte_symbols;
    uint8_t byte_accumulator;
    uint32_t armed_at;
    uint32_t last_symbol_at;
    uint32_t magic_window;
    uint8_t frame[BLE_RGB_FRAME_SIZE];
} ble_rgb_decoder_t;

uint16_t ble_rgb_crc16(const uint8_t *bytes, size_t length);
void ble_rgb_init(ble_rgb_decoder_t *decoder);
void ble_rgb_arm(ble_rgb_decoder_t *decoder, uint32_t now_ms, uint8_t current_led_mask);
void ble_rgb_disarm(ble_rgb_decoder_t *decoder);
void ble_rgb_tick(ble_rgb_decoder_t *decoder, uint32_t now_ms);
/* v3 is hands-free; v1/v2 require a physical arm and remain one-shot. */
bool ble_rgb_receiving(const ble_rgb_decoder_t *decoder);
bool ble_rgb_feed(ble_rgb_decoder_t *decoder, uint32_t now_ms,
                  uint8_t led_mask, ble_rgb_command_t *command);

#endif
