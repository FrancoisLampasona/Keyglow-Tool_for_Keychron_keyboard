/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_reserved_probe.h"
#include "qmk_rgb_ble_bridge.h"
#include "reserved_probe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL adapter line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static uint32_t now = 100;
static matrix_row_t matrix[MATRIX_ROWS];
static uint8_t mods, weak_mods, oneshot_mods, locked_mods, retry, transport = TRANSPORT_BLUETOOTH, wireless = WT_CONNECTED;
static uint16_t consumer, system_usage;
static bool queue_empty = true, low_battery;
static led_t leds;
static report_keyboard_t keyboard;
static report_nkro_t nkro;
report_keyboard_t *keyboard_report = &keyboard;
report_nkro_t *nkro_report = &nkro;
static unsigned sends;
static uint8_t saved_reports[27][8];

uint8_t get_mods(void) { return mods; }
uint8_t get_weak_mods(void) { return weak_mods; }
uint8_t get_oneshot_mods(void) { return oneshot_mods; }
uint8_t get_oneshot_locked_mods(void) { return locked_mods; }
uint16_t host_last_consumer_usage(void) { return consumer; }
uint16_t host_last_system_usage(void) { return system_usage; }
led_t host_keyboard_led_state(void) { return leds; }
bool battery_is_critical_low(void) { return low_battery; }
bool matrix_is_on(uint8_t row, uint8_t col) { return (matrix[row] & ((matrix_row_t)1u << col)) != 0; }
matrix_row_t matrix_get_row(uint8_t row) { return matrix[row]; }
bool report_buffer_is_empty(void) { return queue_empty; }
uint8_t report_buffer_get_retry(void) { return retry; }
uint32_t timer_read32(void) { return now; }
uint8_t get_transport(void) { return transport; }
uint8_t wireless_get_state(void) { return wireless; }
void via_custom_value_command_kb(uint8_t *data, uint8_t length);
void wireless_enter_connected_kb(uint8_t host_idx);

void lkbt51_send_keyboard(uint8_t *report) {
    CHECK(transport == TRANSPORT_BLUETOOTH && wireless == WT_CONNECTED);
    CHECK(!mods && !weak_mods && !oneshot_mods && !locked_mods && !low_battery);
    CHECK(queue_empty && retry == 0 && consumer == 0 && system_usage == 0);
    for (unsigned row = 0; row < MATRIX_ROWS; ++row) CHECK(matrix[row] == 0);
    for (unsigned i = 0; i < 8; ++i) if (i != 1) CHECK(report[i] == 0);
    CHECK(report[1] == 0 || (report[1] & 0xe0u) == 0x80u);
    CHECK(sends < 27); memcpy(saved_reports[sends++], report, 8);
}
static void task(uint32_t elapsed) { now += elapsed; keyglow_probe_task(); }
static uint8_t state(void) {
    uint8_t status[32] = {8, 0x4b, 0x50}; const uint8_t old = transport; transport = TRANSPORT_USB;
    via_custom_value_command_kb(status, sizeof(status)); transport = old;
    CHECK(status[0] == 8 && status[3] == 1); return status[4];
}
static void reset_inputs(void) {
    memset(matrix, 0, sizeof(matrix)); memset(&keyboard, 0, sizeof(keyboard)); memset(&nkro, 0, sizeof(nkro));
    keyboard.report_id = 1; nkro.report_id = 6;
    mods = weak_mods = oneshot_mods = locked_mods = retry = 0;
    queue_empty = true; low_battery = false; consumer = system_usage = 0;
    transport = TRANSPORT_BLUETOOTH; wireless = WT_CONNECTED; sends = 0; task(1);
}
static void arm(void) {
    reset_inputs(); matrix[RGB_BLE_FN_ROW] = (matrix_row_t)1u << RGB_BLE_FN_COL; task(1);
    matrix[RGB_BLE_ARM_ROW] |= (matrix_row_t)1u << RGB_BLE_ARM_COL; task(1); task(2000);
    CHECK(state() == KG_PROBE_WAIT_RELEASE); memset(matrix, 0, sizeof(matrix)); task(1);
    CHECK(state() == KG_PROBE_WAIT_CHALLENGE);
}
static void challenge(void) {
    uint8_t bytes[] = {0x4b, 0x50, 0x52, 0x42, 1, 1, 0x12, 0x34, 0x56, 0x78, 0, 0, 0};
    uint16_t crc = kg_probe_crc16(bytes, 11); bytes[11] = (uint8_t)(crc >> 8); bytes[12] = (uint8_t)crc;
    for (unsigned i = 0; i < sizeof(bytes); ++i) for (int shift = 6; shift >= 0; shift -= 2) {
        now += 80; leds.raw = (uint8_t)(((leds.raw ^ 4u) & 4u) | ((bytes[i] >> shift) & 3u));
        keyglow_probe_led_update(leds); task(0);
    }
    CHECK(state() == KG_PROBE_SETTLING && sends == 0);
}
static void blocked(uint8_t *field) {
    arm(); challenge(); *field = 1; task(600);
    CHECK(state() == KG_PROBE_ABORTED && sends == 0);
}
int main(void) {
    arm(); challenge(); task(600);
    for (unsigned i = 1; i < 27; ++i) task(100);
    CHECK(sends == 27 && state() == KG_PROBE_DONE);
    uint8_t decoded[13] = {0};
    for (unsigned i = 0; i < 26; ++i) {
        CHECK((saved_reports[i][1] & 0xf0u) == (i & 1u ? 0x90u : 0x80u));
        decoded[i / 2] = (uint8_t)((decoded[i / 2] << 4) | (saved_reports[i][1] & 15u));
    }
    const uint8_t prefix[] = {0x4b, 0x50, 0x41, 0x4b, 1, 0, 0x12, 0x34, 0x56, 0x78, 0};
    CHECK(memcmp(decoded, prefix, sizeof(prefix)) == 0);
    CHECK(kg_probe_crc16(decoded, 11) == (((uint16_t)decoded[11] << 8) | decoded[12]));
    for (unsigned i = 0; i < 8; ++i) CHECK(saved_reports[26][i] == 0);

    blocked(&mods); blocked(&weak_mods); blocked(&oneshot_mods); blocked(&locked_mods);
    blocked(&keyboard.mods); blocked(&keyboard.reserved); blocked(&nkro.mods);
    for (unsigned i = 0; i < KEYBOARD_REPORT_KEYS; ++i) blocked(&keyboard.keys[i]);
    for (unsigned i = 0; i < NKRO_REPORT_BITS; ++i) blocked(&nkro.bits[i]);
    for (unsigned row = 0; row < MATRIX_ROWS; ++row) for (unsigned col = 0; col < MATRIX_COLS; ++col) {
        arm(); challenge(); matrix[row] |= (matrix_row_t)1u << col; task(600);
        CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    }
    arm(); challenge(); consumer = 1; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); system_usage = 1; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); low_battery = true; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); transport = TRANSPORT_USB; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); transport = TRANSPORT_P2P4; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); wireless = WT_DISCONNECTED; task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); wireless_enter_connected_kb(1); task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    arm(); challenge(); retry = 1; task(600); CHECK(state() == KG_PROBE_SETTLING && sends == 0);
    retry = 0; task(600); CHECK(sends == 1); retry = 1; task(100); CHECK(state() == KG_PROBE_ABORTED && sends == 1);
    arm(); challenge(); queue_empty = false; task(600); CHECK(state() == KG_PROBE_SETTLING && sends == 0);
    queue_empty = true; task(600); CHECK(sends == 1); queue_empty = false; task(100); CHECK(state() == KG_PROBE_ABORTED && sends == 1);
    arm(); challenge(); keyrecord_t record = {.event = {.key = {.row = 3, .col = 4}, .pressed = true}};
    keyglow_probe_key_event(&record); record.event.pressed = false; keyglow_probe_key_event(&record);
    task(600); CHECK(state() == KG_PROBE_ABORTED && sends == 0);
    printf("QMK probe adapter: %u assertions passed; all report sinks are stubs.\n", checks);
    return 0;
}
