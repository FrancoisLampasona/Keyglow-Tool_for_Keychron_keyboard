/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_mock.h"
#include "qmk_responsive_idle.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "POWER FAIL %d: %s\n", __LINE__, #c); exit(1); } } while (0)
/* Actual battery getters AND Q6 board idle hook from the pinned patched tree. */
#include Q6_BATTERY_TEST_SOURCE

static uint8_t transport;
static wt_state_t state;
static uint16_t timeout_seconds;
static bool initial_sampling, empty, critical;
uint8_t get_transport(void) { return transport; }
wt_state_t wireless_get_state(void) { return state; }
uint16_t wireless_get_connected_idle_timeout(void) { return timeout_seconds; }
bool battery_power_on_sample(void) { return initial_sampling; }
bool battery_is_empty(void) { return empty; }
bool battery_is_critical_low(void) { return critical; }

int main(void) {
    transport = TRANSPORT_BLUETOOTH; state = WT_CONNECTED;
    timeout_seconds = Q6_RESPONSIVE_IDLE_SECONDS;
    /* Stock's 4100mV default must never count as a measured battery. */
    CHECK(battery_get_voltage() == FULL_VOLTAGE_VALUE);
    CHECK(!battery_has_valid_reading());
    CHECK(lpm_is_kb_idle());
    battery_set_voltage(4100); initial_sampling = true;
    CHECK(battery_has_valid_reading() && lpm_is_kb_idle());
    initial_sampling = false; CHECK(!lpm_is_kb_idle());
    battery_init(); CHECK(!battery_has_valid_reading() && lpm_is_kb_idle());

    const uint8_t transports[] = {TRANSPORT_NONE, TRANSPORT_USB, TRANSPORT_BLUETOOTH, TRANSPORT_P2P4, 6, 255};
    const unsigned states[] = {WT_RESET,WT_INITIALIZED,WT_DISCONNECTED,WT_CONNECTED,WT_PARING,WT_RECONNECTING,WT_SUSPEND,255};
    const uint16_t timeouts[] = {0,1,59,60,7200,65519,65520,65521,65535};
    const uint16_t voltages[] = {0,3299,3300,3499,3500,3501,4100,4200,4400,4401,65535};
    unsigned cases = 0, active_cases = 0;
    for (unsigned t=0; t<sizeof(transports)/sizeof(transports[0]); ++t)
    for (unsigned s=0; s<sizeof(states)/sizeof(states[0]); ++s)
    for (unsigned timeout=0; timeout<sizeof(timeouts)/sizeof(timeouts[0]); ++timeout)
    for (unsigned v=0; v<sizeof(voltages)/sizeof(voltages[0]); ++v)
    for (unsigned flags=0; flags<16; ++flags)
    for (unsigned guards=0; guards<4; ++guards) {
        transport = transports[t]; state = (wt_state_t)states[s]; timeout_seconds = timeouts[timeout];
        battery_set_voltage(voltages[v]);
        if (!(flags & 1u)) battery_init(); /* no real measurement since init */
        initial_sampling = (flags & 2u) != 0;
        empty = (flags & 4u) != 0;
        critical = (flags & 8u) != 0;
        power_on_indicator_timer = (guards & 1u) ? 10u : 0u;
        test_backlight_indicator = (guards & 2u) != 0;
        /* Only a fully healthy connected preset is allowed to veto MCU idle. */
        const bool allowed = transport == TRANSPORT_BLUETOOTH && state == WT_CONNECTED &&
            timeout_seconds == 65520 && flags == 1 && voltages[v] > 3500 && voltages[v] <= 4400;
        CHECK(q6_responsive_idle_active() == allowed);
        CHECK(lpm_is_kb_idle() == (guards == 0 && !allowed));
        ++cases; if (allowed) ++active_cases;
    }
    CHECK(cases == 304128 && active_cases == 16);

    transport = TRANSPORT_BLUETOOTH; state = WT_CONNECTED;
    power_on_indicator_timer = 0; test_backlight_indicator = false;
    timeout_seconds = 65520; initial_sampling = empty = critical = false;
    battery_set_voltage(3900); CHECK(!lpm_is_kb_idle());
    timeout_seconds = 7200; CHECK(lpm_is_kb_idle());
    timeout_seconds = 65520; CHECK(!lpm_is_kb_idle());
    battery_set_voltage(3500); CHECK(lpm_is_kb_idle()); /* immediate low-voltage fallback, before counters */
    battery_set_voltage(3900); CHECK(!lpm_is_kb_idle());
    state = WT_SUSPEND; CHECK(lpm_is_kb_idle());
    state = WT_CONNECTED; CHECK(!lpm_is_kb_idle());
    battery_init(); CHECK(lpm_is_kb_idle()); /* resume/init requires another measurement */
    printf("PASS: %u power-policy combinations; REAL Q6 idle hook preserves power-on/backlight guards, BT/state/preset opt-in, battery validity, low/critical/unknown fallback and immediate disable; no hardware.\n", cases);
    return 0;
}
