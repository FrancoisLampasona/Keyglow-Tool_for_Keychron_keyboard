/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#define LK_WIRELESS_ENABLE
#define RGB_MATRIX_ENABLE
#define NKRO_ENABLE
#define MATRIX_ROWS 6
#define MATRIX_COLS 21
#define KEYBOARD_REPORT_KEYS 6
#define NKRO_REPORT_BITS 30
typedef uint32_t matrix_row_t;
typedef union { uint8_t raw; } led_t;
typedef struct { struct { struct { uint8_t row, col; } key; bool pressed; } event; } keyrecord_t;
typedef struct { uint8_t report_id, mods, reserved, keys[KEYBOARD_REPORT_KEYS]; } report_keyboard_t;
typedef struct { uint8_t report_id, mods, bits[NKRO_REPORT_BITS]; } report_nkro_t;
extern report_keyboard_t *keyboard_report;
extern report_nkro_t *nkro_report;
enum { TRANSPORT_USB = 1, TRANSPORT_BLUETOOTH = 2, TRANSPORT_P2P4 = 4, WT_CONNECTED = 3, WT_DISCONNECTED = 2 };
uint8_t get_mods(void);
uint8_t get_weak_mods(void);
uint8_t get_oneshot_mods(void);
uint8_t get_oneshot_locked_mods(void);
uint16_t host_last_consumer_usage(void);
uint16_t host_last_system_usage(void);
led_t host_keyboard_led_state(void);
bool battery_is_critical_low(void);
bool matrix_is_on(uint8_t row, uint8_t col);
matrix_row_t matrix_get_row(uint8_t row);
bool report_buffer_is_empty(void);
uint8_t report_buffer_get_retry(void);
uint32_t timer_read32(void);
uint8_t get_transport(void);
uint8_t wireless_get_state(void);
void lkbt51_send_keyboard(uint8_t *report);
