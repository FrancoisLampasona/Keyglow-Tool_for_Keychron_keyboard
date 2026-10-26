/* SPDX-License-Identifier: GPL-2.0-or-later */
#include QMK_KEYBOARD_H
#include "qmk_responsive_idle.h"
#include "transport.h"
#include "wireless.h"
#include "battery.h"
#include "lpm.h"

#if !defined(LK_WIRELESS_ENABLE) || !defined(WIRELESS_CONFIG_ENABLE)
#    error "The responsive preset requires Q6 Max LK wireless configuration."
#endif

bool q6_responsive_idle_active(void) {
    if (get_transport() != TRANSPORT_BLUETOOTH || wireless_get_state() != WT_CONNECTED) return false;
    if (wireless_get_connected_idle_timeout() != Q6_RESPONSIVE_IDLE_SECONDS) return false;
    /* Initial voltage is a synthetic FULL_VOLTAGE_VALUE in stock firmware.
     * Wait for a real plausible reading and the normal initial sample window. */
    if (!battery_has_valid_reading() || battery_power_on_sample()) return false;
    if (battery_is_empty() || battery_is_critical_low()) return false;
    /* Do not wait for Keychron's low-battery counters to accumulate. */
    return battery_get_voltage() > EMPTY_VOLTAGE_VALUE;
}

/* Additional veto called by the ORIGINAL Q6 lpm_is_kb_idle(), which retains
 * its power-on and backlight indicator guards. True only permits those stock
 * checks; it does not itself put the MCU to sleep. No writes or reports. */
bool q6_lpm_is_idle_user(void) {
    return !q6_responsive_idle_active();
}
