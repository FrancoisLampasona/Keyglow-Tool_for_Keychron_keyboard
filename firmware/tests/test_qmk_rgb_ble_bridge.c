/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_rgb_ble_bridge.h"
#include "ble_rgb_protocol.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "BRIDGE FAIL line %d: %s\n", __LINE__, #condition); exit(1); \
} } while (0)

static uint32_t now;
static uint8_t transport;
static wt_state_t wireless_state = WT_CONNECTED;
static unsigned persisted, demo_persisted;
static bool scan_during_send=true;
static bool keys[6][20];
static led_t host_leds;
static bool matrix_enabled;
uint8_t retail_demo_enable;
mock_usb_t mock_usb;
static struct {
    unsigned enabled, disabled, modes, hsv, speeds, overlays;
    uint8_t mode, hue, saturation, value, speed;
    bool num, caps;
} calls;

wt_state_t wireless_get_state(void) { return wireless_state; }
void rgb_matrix_save_lighting(void) { ++persisted; }
void rgb_save_retail_demo_if_changed(void) { ++demo_persisted; }
uint8_t get_transport(void) { return transport; }
uint32_t timer_read32(void) { return now; }
bool matrix_is_on(uint8_t row, uint8_t col) { CHECK(row < 6 && col < 20); return keys[row][col]; }
led_t host_keyboard_led_state(void) { return host_leds; }
void rgb_matrix_disable_noeeprom(void) { ++calls.disabled; matrix_enabled = false; }
void rgb_matrix_enable_noeeprom(void) {
    ++calls.enabled; matrix_enabled = true;
    /* Keychron's enable helper lifts low brightness before custom setters. */
    if (calls.value < 48) calls.value = 48;
}
void rgb_matrix_mode_noeeprom(uint8_t mode) {
    if (!matrix_enabled) return; /* matches the pinned Keychron implementation */
    ++calls.modes; calls.mode = mode;
}
void rgb_matrix_sethsv_noeeprom(uint16_t hue, uint8_t saturation, uint8_t value) {
    if (!matrix_enabled) return;
    ++calls.hsv; calls.hue = (uint8_t)hue; calls.saturation = saturation; calls.value = value;
}
void rgb_matrix_set_speed_noeeprom(uint8_t speed) { ++calls.speeds; calls.speed = speed; }
uint8_t rgb_matrix_get_speed(void) { return calls.speed; }
void rgb_matrix_set_config_noeeprom(uint8_t mode, uint16_t hue, uint8_t sat, uint8_t val, uint8_t speed) {
    rgb_matrix_enable_noeeprom();
    rgb_matrix_mode_noeeprom(mode);
    rgb_matrix_sethsv_noeeprom(hue, sat, val);
    rgb_matrix_set_speed_noeeprom(speed);
}
void rgb_matrix_set_color(int index, uint8_t red, uint8_t green, uint8_t blue) {
    CHECK(red == 255 && green == 255 && blue == 255);
    CHECK(index == NUM_LOCK_INDEX || index == CAPS_LOCK_INDEX);
    ++calls.overlays;
    if (index == NUM_LOCK_INDEX) calls.num = true;
    if (index == CAPS_LOCK_INDEX) calls.caps = true;
}

static bool graphic_record(bool pressed) {
    /* Arbitrary remapped keycode does not affect physical position handling. */
    keyrecord_t record = {.event = {.key = {.row = RGB_BLE_ARM_ROW, .col = RGB_BLE_ARM_COL}, .pressed = pressed}};
    return rgb_ble_bridge_process_record(0xffff, &record);
}
static void scan_after(uint32_t elapsed) { now += elapsed; rgb_ble_bridge_matrix_scan(); }
static void release_chord(void) {
    (void)graphic_record(false);
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = false;
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = false;
    scan_after(1);
}
static void reset(uint8_t led_mask) {
    transport = TRANSPORT_USB;
    memset(keys, 0, sizeof(keys));
    (void)graphic_record(false);
    scan_after(1);
    transport = TRANSPORT_BLUETOOTH;
    wireless_state = WT_CONNECTED;
    persisted = demo_persisted = 0;
    scan_during_send=true;
    host_leds.raw = led_mask;
    mock_usb.state = 0;
    matrix_enabled = false;
    retail_demo_enable = 1;
    memset(&calls, 0, sizeof(calls));
}
static void hold_chord(void) {
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = true;
    scan_after(1);
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = true;
    CHECK(!graphic_record(true));
    scan_after(1);
    scan_after(RGB_BLE_HOLD_MS);
    CHECK(!graphic_record(false));
    release_chord();
}
static void arm(void) { hold_chord(); CHECK(rgb_ble_bridge_is_armed()); }
static void send_bytes(const uint8_t *frame, size_t length) {
    uint8_t clock = 0;
    uint8_t original = host_leds.raw;
    host_leds.raw = original & 0xf8u;
    now += 80;
    CHECK(rgb_ble_bridge_led_update(host_leds));
    for (size_t i = 0; i < length; ++i) {
        for (int shift = 6; shift >= 0; shift -= 2) {
            clock ^= 4u;
            host_leds.raw = (uint8_t)((original & 0xf8u) | clock | ((frame[i] >> shift) & 3u));
            now += 80;
            CHECK(rgb_ble_bridge_led_update(host_leds));
            if (scan_during_send) rgb_ble_bridge_matrix_scan();
        }
    }
    host_leds.raw = original;
    CHECK(rgb_ble_bridge_led_update(host_leds));
}
static void send_state(uint8_t mode, uint8_t hue, uint8_t saturation, uint8_t value, uint8_t speed) {
    uint8_t frame[13] = {0x4b, 0x52, 0x47, 0x42, 2, 3, mode, hue, saturation, value, speed, 0, 0};
    uint16_t crc = ble_rgb_crc16(frame, 11);
    frame[11] = (uint8_t)(crc >> 8); frame[12] = (uint8_t)crc;
    send_bytes(frame, sizeof(frame));
}
static void send_v3(uint8_t command, uint8_t mode, uint8_t value) {
    uint8_t frame[13] = {0x4b,0x52,0x47,0x42,3,command,mode,85,255,value,200,0,0};
    if (mode==0) memset(frame+7,0,4);
    uint16_t crc=ble_rgb_crc16(frame,11); frame[11]=(uint8_t)(crc>>8); frame[12]=(uint8_t)crc;
    send_bytes(frame,sizeof(frame));
}

static void overlay(void) {
    led_t filtered = keychron_filter_os_indicator_state(host_leds);
    calls.num = filtered.num_lock;
    calls.caps = filtered.caps_lock;
    CHECK((filtered.raw & 0xfcu) == (host_leds.raw & 0xfcu));
}

int main(void) {
    reset(0);
    send_state(1, 0, 255, 255, 127);
    CHECK(calls.enabled == 0 && calls.disabled == 0); /* host cannot arm */
    CHECK(retail_demo_enable == 1);

    /* Short holds and reversed key order do not arm. */
    reset(0);
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = true; scan_after(1);
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = true; scan_after(1);
    scan_after(RGB_BLE_HOLD_MS - 1u);
    CHECK(!rgb_ble_bridge_is_armed());
    release_chord(); scan_after(2);
    CHECK(!rgb_ble_bridge_is_armed());
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = true; scan_after(1);
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = true; scan_after(1);
    scan_after(RGB_BLE_HOLD_MS);
    CHECK(!rgb_ble_bridge_is_armed());
    release_chord();

    /* Hold only fires once, expires absolutely, and a fresh chord can cancel. */
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = true; scan_after(1);
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = true; scan_after(1);
    scan_after(RGB_BLE_HOLD_MS); CHECK(rgb_ble_bridge_is_armed());
    scan_after(BLE_RGB_ARM_MS); CHECK(!rgb_ble_bridge_is_armed());
    scan_after(RGB_BLE_HOLD_MS); CHECK(!rgb_ble_bridge_is_armed());
    release_chord(); arm(); hold_chord(); CHECK(!rgb_ble_bridge_is_armed());
    send_state(1, 0, 255, 255, 127); CHECK(calls.enabled == 0);

    /* Non-Bluetooth never consumes or arms; changing transport disarms. */
    reset(0); transport = TRANSPORT_USB;
    keys[RGB_BLE_FN_ROW][RGB_BLE_FN_COL] = true; scan_after(1);
    keys[RGB_BLE_ARM_ROW][RGB_BLE_ARM_COL] = true;
    CHECK(graphic_record(true)); scan_after(1); scan_after(RGB_BLE_HOLD_MS);
    CHECK(!rgb_ble_bridge_is_armed());
    release_chord(); transport = TRANSPORT_BLUETOOTH; arm();
    transport = TRANSPORT_USB; scan_after(1); CHECK(!rgb_ble_bridge_is_armed());
    send_state(1, 0, 255, 255, 127); CHECK(calls.enabled == 0);

    for (uint8_t mode = 1; mode <= BLE_RGB_MODE_MAX; ++mode) {
        reset(0x18); arm(); send_state(mode, 85, 192, 255, 200);
        CHECK(!rgb_ble_bridge_is_armed());
        CHECK(retail_demo_enable == 0);
        CHECK(calls.enabled == 1 && calls.disabled == 0 && calls.modes == 1 && calls.hsv == 1 && calls.speeds == 1);
        CHECK(calls.mode == RGB_MATRIX_SOLID_COLOR + mode - 1);
        CHECK(calls.hue == 85 && calls.saturation == 192 && calls.value == 180 && calls.speed == 200);
        CHECK(host_leds.raw == 0x18);
        send_state(mode, 0, 0, 0, 0); CHECK(calls.enabled == 1); /* one shot */
    }
    reset(0); arm(); send_state(1, 255, 0, 128, 0);
    CHECK(calls.value == 90 && calls.speed == 0);
    reset(0); arm(); send_state(22, 0, 255, 0, 255);
    CHECK(calls.value == 0 && calls.speed == 255 && calls.mode == RGB_MATRIX_SOLID_SPLASH);
    reset(0); arm(); send_state(0, 0, 0, 0, 0);
    CHECK(calls.disabled == 1 && calls.enabled == 0 && calls.modes == 0 && calls.hsv == 0 && calls.speeds == 0);
    CHECK(retail_demo_enable == 0);
    reset(0); arm(); send_state(23, 0, 0, 0, 0);
    CHECK(calls.disabled == 0 && calls.enabled == 0 && rgb_ble_bridge_is_armed());
    CHECK(retail_demo_enable == 1); /* rejected commands cannot change demo state */
    send_state(1, 0, 255, 255, 127); CHECK(calls.enabled == 1);

    /* Legacy static commands keep the current animation speed. */
    const uint8_t v1_red[11] = {0x4b,0x52,0x47,0x42,1,1,0,255,255,0xe3,0xc0};
    reset(0); arm(); calls.speed = 42;
    send_bytes(v1_red, sizeof(v1_red));
    CHECK(calls.mode == RGB_MATRIX_SOLID_COLOR && calls.value == 180 && calls.speed == 42 && calls.speeds == 1);

    /* Freeze only Caps/Num while armed and for the sender's final LED restore. */
    reset(1); arm(); host_leds.raw = 3; overlay();
    CHECK(calls.num && !calls.caps);
    for (unsigned mask = 0; mask < 256; ++mask) {
        host_leds.raw = (uint8_t)mask; overlay();
        CHECK(calls.num && !calls.caps); /* all other bits pass through unchanged */
    }
    send_state(1, 0, 255, 255, 127);
    CHECK(!rgb_ble_bridge_is_armed());
    host_leds.raw = 2; overlay(); CHECK(calls.num && !calls.caps);
    scan_after(RGB_BLE_INDICATOR_TAIL_MS - 1u); overlay(); CHECK(calls.num && !calls.caps);
    scan_after(1); overlay(); CHECK(!calls.num && calls.caps);
    transport = TRANSPORT_USB; host_leds.raw = 3;
    overlay(); CHECK(calls.num && calls.caps); /* USB passes through unchanged */

    /* Both hold timing and receive timing work across a 32-bit rollover. */
    reset(0); now = UINT32_MAX - 1000u; arm();
    send_state(20, 85, 192, 128, 200);
    CHECK(calls.enabled == 1 && calls.mode == RGB_MATRIX_SOLID_REACTIVE_MULTINEXUS);

    /* v3 direct control needs no chord; preview and save are distinct. */
    reset(0x18); send_v3(3,2,255);
    CHECK(!rgb_ble_bridge_is_armed() && calls.mode == RGB_MATRIX_BREATHING);
    CHECK(calls.hue==85 && calls.value==180 && calls.speed==200);
    CHECK(persisted==0 && demo_persisted==0 && retail_demo_enable==0);
    send_v3(4,1,128); CHECK(calls.mode==RGB_MATRIX_SOLID_COLOR && calls.value==90);
    CHECK(persisted==1 && demo_persisted==1);
    send_v3(4,0,0); CHECK(!matrix_enabled && persisted==2 && demo_persisted==2);
    send_v3(4,2,255); CHECK(matrix_enabled && persisted==3);
    for (uint8_t mode=1; mode<=22; ++mode) {
        reset(0); send_v3(4,mode,255);
        CHECK(calls.mode==RGB_MATRIX_SOLID_COLOR+mode-1 && persisted==1);
    }
    reset(0); send_v3(5,2,255); CHECK(persisted==0 && calls.enabled==0);
    reset(0); transport=TRANSPORT_USB; send_v3(4,2,255);
    CHECK(persisted==0 && calls.enabled==0);
    reset(0); wireless_state=WT_DISCONNECTED; send_v3(4,2,255);
    CHECK(persisted==0 && calls.enabled==0);
    reset(0); scan_during_send=false; send_v3(4,2,255);
    CHECK(persisted==0 && calls.enabled==0); /* callback only queues */
    scan_after(1); CHECK(persisted==1 && calls.mode==RGB_MATRIX_BREATHING);
    reset(0); scan_during_send=false; send_v3(4,2,255);
    transport=TRANSPORT_USB; scan_after(1); CHECK(persisted==0 && calls.enabled==0);
    reset(0); scan_during_send=false; send_v3(4,2,255);
    wireless_state=WT_DISCONNECTED; scan_after(1); CHECK(persisted==0 && calls.enabled==0);
    /* Normal Caps/Num states are untouched outside packet/tail windows. */
    reset(0); scan_after(1000);
    for (uint8_t mask=0;mask<4;++mask) {
        host_leds.raw=mask; rgb_ble_bridge_led_update(host_leds); overlay();
        CHECK(calls.num==((mask&1)!=0) && calls.caps==((mask&2)!=0));
    }
    send_v3(4,2,255); scan_after(RGB_BLE_INDICATOR_TAIL_MS);
    host_leds.raw=2; overlay(); CHECK(!calls.num && calls.caps);
    puts("PASS: v3 automatic direct preview/save, every effect, OFF/re-enable, no writes for preview/invalid/USB/disconnected, normal lock indicators outside receive window.");
    puts("PASS: QMK bridge physical hold/cancel/expiry/transport gate, all explicit effects, enable-before-set and full brightness/speed, RAM-only retail-demo stop, v1, one-shot, Caps/Num-only filter (256 masks) and rollover (mock APIs, no hardware).");
    return 0;
}
