/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <stdbool.h>
#include <stdint.h>
bool battery_has_valid_reading(void);
bool battery_power_on_sample(void);
bool battery_is_critical_low(void);
uint16_t battery_get_voltage(void);
