/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef QMK_BLE_OTA_H
#define QMK_BLE_OTA_H
#include "quantum.h"
/* All hooks run in the foreground QMK task, never an ISR. Put the LED hook
 * before RGB decoding; false means the RGB decoder must not see this symbol. */
bool keyglow_ble_ota_led_update(led_t state);
void keyglow_ble_ota_process_record(keyrecord_t *record);
void keyglow_ble_ota_task(void);
bool keyglow_ble_ota_busy(void);
void keyglow_ble_ota_link_changed(void);
#endif
