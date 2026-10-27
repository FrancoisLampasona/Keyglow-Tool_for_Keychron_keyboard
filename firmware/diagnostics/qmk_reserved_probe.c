/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_reserved_probe.h"
#include "reserved_probe.h"
#include "qmk_rgb_ble_bridge.h"
#include "action_util.h"
#include "battery.h"
#include "host.h"
#include "lkbt51.h"
#include "matrix.h"
#include "report_buffer.h"
#include "timer.h"
#include "transport.h"
#include "wireless.h"

#if !defined(LK_WIRELESS_ENABLE) || !defined(RGB_MATRIX_ENABLE)
#    error "This diagnostic is limited to the Q6 Max ISO LKBT51 build."
#endif

static kg_probe_t probe;

static bool logical_idle(void) {
    if (get_mods() || get_weak_mods() || get_oneshot_mods() || get_oneshot_locked_mods()) return false;
    if (keyboard_report->mods || keyboard_report->reserved) return false;
    for (uint8_t i = 0; i < KEYBOARD_REPORT_KEYS; ++i) if (keyboard_report->keys[i]) return false;
#ifdef NKRO_ENABLE
    if (nkro_report->mods) return false;
    for (uint8_t i = 0; i < NKRO_REPORT_BITS; ++i) if (nkro_report->bits[i]) return false;
#endif
    return host_last_consumer_usage() == 0 && host_last_system_usage() == 0;
}

static kg_probe_input_t input_snapshot(uint8_t led_mask) {
    kg_probe_input_t input = {
        .now = timer_read32(),
        .connected = get_transport() == TRANSPORT_BLUETOOTH && wireless_get_state() == WT_CONNECTED,
        .fn_down = matrix_is_on(RGB_BLE_FN_ROW, RGB_BLE_FN_COL),
        .arm_down = matrix_is_on(RGB_BLE_ARM_ROW, RGB_BLE_ARM_COL),
        .logical_idle = logical_idle(),
        .queue_idle = report_buffer_is_empty() && report_buffer_get_retry() == 0,
        .battery_ok = !battery_is_critical_low(),
        .led_mask = led_mask,
    };
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) {
        matrix_row_t occupied = matrix_get_row(row);
        if (row == RGB_BLE_FN_ROW) occupied &= ~((matrix_row_t)1u << RGB_BLE_FN_COL);
        if (row == RGB_BLE_ARM_ROW) occupied &= ~((matrix_row_t)1u << RGB_BLE_ARM_COL);
        if (occupied != 0) input.other_key_down = true;
    }
    return input;
}

void keyglow_probe_key_event(keyrecord_t *record) {
    const bool chord_key = (record->event.key.row == RGB_BLE_FN_ROW && record->event.key.col == RGB_BLE_FN_COL) ||
                           (record->event.key.row == RGB_BLE_ARM_ROW && record->event.key.col == RGB_BLE_ARM_COL);
    kg_probe_key_event(&probe, chord_key, record->event.pressed);
}

void keyglow_probe_led_update(led_t state) {
    const kg_probe_input_t input = input_snapshot(state.raw);
    kg_probe_feed_led(&probe, &input);
}

void keyglow_probe_task(void) {
    const kg_probe_input_t input = input_snapshot(host_keyboard_led_state().raw);
    uint8_t report[8];
    if (kg_probe_tick(&probe, &input, report)) {
        /* Candidate only: the radio/host may discard the reserved byte.
         * This calls the existing 0x11 keyboard-report path, never DFU or raw-HID radio commands.
         * Nothing is enqueued for delayed emission after typing resumes. */
        lkbt51_send_keyboard(report);
    }
}

/* The original hook is empty. Catch even disconnect/reconnect pairs processed
 * within one housekeeping pass before any subsequent diagnostic report. */
void wireless_enter_connected_kb(uint8_t host_idx) {
    (void)host_idx;
    kg_probe_abort(&probe, KG_PROBE_ABORT_LINK);
}

void via_custom_value_command_kb(uint8_t *data, uint8_t length) {
    kg_probe_status(&probe, get_transport() == TRANSPORT_USB, data, length);
}
