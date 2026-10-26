/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <stdbool.h>
#include <stdint.h>

/* Explicit opt-in contract with the app's 1092-minute USB preset. */
#define Q6_RESPONSIVE_IDLE_SECONDS UINT16_C(65520)

bool q6_responsive_idle_active(void);
bool q6_lpm_is_idle_user(void);
