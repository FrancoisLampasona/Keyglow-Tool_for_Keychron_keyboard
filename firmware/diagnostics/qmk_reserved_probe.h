/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include QMK_KEYBOARD_H
void keyglow_probe_key_event(keyrecord_t *record);
void keyglow_probe_led_update(led_t state);
void keyglow_probe_task(void);
