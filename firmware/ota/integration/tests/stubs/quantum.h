/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t syssts_t;
#define MATRIX_ROWS 1
#define USB_POWER_SENSE_PIN 0
#define USB_POWER_CONNECTED_LEVEL 0
syssts_t chSysGetStatusAndLockX(void);
void chSysRestoreStatusX(syssts_t state);
uint32_t timer_read32(void);
uint32_t timer_elapsed32(uint32_t last);
uint8_t get_mods(void);
uint8_t get_weak_mods(void);
uint32_t matrix_get_row(uint8_t row);
bool readPin(unsigned pin);
void NVIC_SystemReset(void);
