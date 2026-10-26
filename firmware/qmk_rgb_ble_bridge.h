/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include QMK_KEYBOARD_H

/* Q6 Max ISO physical positions; independent of VIA's stored keycodes. */
#define RGB_BLE_FN_ROW 5u
#define RGB_BLE_FN_COL 12u
#define RGB_BLE_ARM_ROW 0u
#define RGB_BLE_ARM_COL 17u
#define RGB_BLE_HOLD_MS 2000u
#define RGB_BLE_INDICATOR_TAIL_MS 600u

bool rgb_ble_bridge_process_record(uint16_t keycode, keyrecord_t *record);
bool rgb_ble_bridge_led_update(led_t led_state);
void rgb_ble_bridge_matrix_scan(void);
bool rgb_ble_bridge_is_armed(void);
/* Hook added by apply-qmk-patch.py to the two existing OS indicator renderers. */
led_t keychron_filter_os_indicator_state(led_t state);
