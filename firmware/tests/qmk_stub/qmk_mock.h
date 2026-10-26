/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#define RGB_MATRIX_ENABLE
#define LK_WIRELESS_ENABLE
#define WIRELESS_CONFIG_ENABLE
#define KEYCHRON_RGB_ENABLE
#define RETAIL_DEMO_ENABLE
#define RGB_MATRIX_SLEEP
#define RGB_MATRIX_MAXIMUM_BRIGHTNESS 180u
#define NUM_LOCK_INDEX 37
#define CAPS_LOCK_INDEX 62
#define TRANSPORT_USB 1u
#define TRANSPORT_BLUETOOTH 2u
#define TRANSPORT_NONE 0u
#define TRANSPORT_P2P4 4u
#define FULL_VOLTAGE_VALUE 4100u
#define EMPTY_VOLTAGE_VALUE 3500u
#define SHUTDOWN_VOLTAGE_VALUE 3300u
#define BAT_NOT_CHARGING 0u
#define USB_SUSPENDED 5u
#define USB_DRIVER mock_usb

typedef union {
    uint8_t raw;
    struct {
        uint8_t num_lock : 1;
        uint8_t caps_lock : 1;
        uint8_t scroll_lock : 1;
        uint8_t compose : 1;
        uint8_t kana : 1;
        uint8_t reserved : 3;
    };
} led_t;
typedef struct {
    struct { struct { uint8_t row, col; } key; bool pressed; } event;
} keyrecord_t;
typedef struct { uint8_t state; } mock_usb_t;
extern mock_usb_t mock_usb;
typedef enum { WT_RESET, WT_INITIALIZED, WT_DISCONNECTED, WT_CONNECTED, WT_PARING, WT_RECONNECTING, WT_SUSPEND } wt_state_t;
wt_state_t wireless_get_state(void);
uint16_t wireless_get_connected_idle_timeout(void);
bool battery_has_valid_reading(void);
bool battery_power_on_sample(void);
bool battery_is_empty(void);
bool battery_is_critical_low(void);
uint16_t battery_get_voltage(void);
void battery_set_voltage(uint16_t value);
void battery_init(void);
bool lpm_is_kb_idle(void);

/* Deliberately different from wire IDs: a direct mode passthrough must fail. */
enum {
    RGB_MATRIX_NONE = 0, RGB_MATRIX_SOLID_COLOR = 80,
    RGB_MATRIX_BREATHING, RGB_MATRIX_BAND_SPIRAL_VAL, RGB_MATRIX_CYCLE_ALL,
    RGB_MATRIX_CYCLE_LEFT_RIGHT, RGB_MATRIX_CYCLE_UP_DOWN, RGB_MATRIX_RAINBOW_MOVING_CHEVRON,
    RGB_MATRIX_CYCLE_OUT_IN, RGB_MATRIX_CYCLE_OUT_IN_DUAL, RGB_MATRIX_CYCLE_PINWHEEL,
    RGB_MATRIX_CYCLE_SPIRAL, RGB_MATRIX_DUAL_BEACON, RGB_MATRIX_RAINBOW_BEACON,
    RGB_MATRIX_JELLYBEAN_RAINDROPS, RGB_MATRIX_PIXEL_RAIN, RGB_MATRIX_TYPING_HEATMAP,
    RGB_MATRIX_DIGITAL_RAIN, RGB_MATRIX_SOLID_REACTIVE_SIMPLE, RGB_MATRIX_SOLID_REACTIVE_MULTIWIDE,
    RGB_MATRIX_SOLID_REACTIVE_MULTINEXUS, RGB_MATRIX_SPLASH, RGB_MATRIX_SOLID_SPLASH
};
uint8_t get_transport(void);
uint32_t timer_read32(void);
bool matrix_is_on(uint8_t row, uint8_t col);
led_t host_keyboard_led_state(void);
void rgb_matrix_disable_noeeprom(void);
void rgb_matrix_enable_noeeprom(void);
void rgb_matrix_mode_noeeprom(uint8_t mode);
void rgb_matrix_sethsv_noeeprom(uint16_t hue, uint8_t saturation, uint8_t value);
void rgb_matrix_set_speed_noeeprom(uint8_t speed);
uint8_t rgb_matrix_get_speed(void);
void rgb_matrix_set_config_noeeprom(uint8_t mode, uint16_t hue, uint8_t sat, uint8_t val, uint8_t speed);
void rgb_matrix_save_lighting(void);
void rgb_save_retail_demo_if_changed(void);
void rgb_matrix_set_color(int index, uint8_t red, uint8_t green, uint8_t blue);
void os_state_indicate(void);
