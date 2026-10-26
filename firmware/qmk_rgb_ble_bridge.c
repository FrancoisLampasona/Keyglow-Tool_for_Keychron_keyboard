/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_rgb_ble_bridge.h"
#include "ble_rgb_protocol.h"
#include "host.h"
#include "matrix.h"
#include "transport.h"
#include "wireless.h"
#include "rgb_matrix.h"
#include "timer.h"

#if !defined(RGB_MATRIX_ENABLE) || !defined(LK_WIRELESS_ENABLE)
#    error "The BLE RGB bridge requires Q6 Max RGB Matrix and LK wireless support."
#endif
#if !defined(NUM_LOCK_INDEX) || NUM_LOCK_INDEX != 37 || !defined(CAPS_LOCK_INDEX) || CAPS_LOCK_INDEX != 62
#    error "This bridge is specifically for Q6 Max ISO (Num 37, Caps 62)."
#endif

static ble_rgb_decoder_t decoder;
static bool arm_key_was_down;
static bool hold_pending;
static bool arm_key_consumed;
static uint32_t hold_started;
static uint8_t original_led_mask;
static bool indicator_tail;
static uint32_t indicator_tail_started;
static uint8_t previous_led_mask;
static uint8_t candidate_led_mask;
static bool listener_connected;
static bool pending_command_valid;
static ble_rgb_command_t pending_command;

static bool bluetooth_connected(void) {
    return get_transport() == TRANSPORT_BLUETOOTH && wireless_get_state() == WT_CONNECTED;
}

static void reset_listener(void) {
    ble_rgb_disarm(&decoder);
    indicator_tail = false;
    pending_command_valid = false;
    listener_connected = false;
}

static void sync_listener(void) {
    if (!listener_connected) {
        ble_rgb_init(&decoder);
        previous_led_mask = host_keyboard_led_state().raw;
        candidate_led_mask = previous_led_mask;
        decoder.last_clock = (uint8_t)((previous_led_mask >> 2) & 1u);
        listener_connected = true;
    }
}

/* Stable wire IDs, not QMK enum ordinals. From the enabled animations in the
 * pinned Keychron 2025q3 Q6 Max info.json. Custom per-key/Mix modes are excluded. */
static const uint8_t qmk_effects[BLE_RGB_MODE_MAX + 1u] = {
    RGB_MATRIX_NONE,
    RGB_MATRIX_SOLID_COLOR,
    RGB_MATRIX_BREATHING,
    RGB_MATRIX_BAND_SPIRAL_VAL,
    RGB_MATRIX_CYCLE_ALL,
    RGB_MATRIX_CYCLE_LEFT_RIGHT,
    RGB_MATRIX_CYCLE_UP_DOWN,
    RGB_MATRIX_RAINBOW_MOVING_CHEVRON,
    RGB_MATRIX_CYCLE_OUT_IN,
    RGB_MATRIX_CYCLE_OUT_IN_DUAL,
    RGB_MATRIX_CYCLE_PINWHEEL,
    RGB_MATRIX_CYCLE_SPIRAL,
    RGB_MATRIX_DUAL_BEACON,
    RGB_MATRIX_RAINBOW_BEACON,
    RGB_MATRIX_JELLYBEAN_RAINDROPS,
    RGB_MATRIX_PIXEL_RAIN,
    RGB_MATRIX_TYPING_HEATMAP,
    RGB_MATRIX_DIGITAL_RAIN,
    RGB_MATRIX_SOLID_REACTIVE_SIMPLE,
    RGB_MATRIX_SOLID_REACTIVE_MULTIWIDE,
    RGB_MATRIX_SOLID_REACTIVE_MULTINEXUS,
    RGB_MATRIX_SPLASH,
    RGB_MATRIX_SOLID_SPLASH,
};

bool rgb_ble_bridge_is_armed(void) {
    return decoder.armed;
}

static void start_indicator_tail(uint32_t now) {
    /* Keep the last CRC symbol out of Caps/Num until the sender restores LEDs. */
    indicator_tail = true;
    indicator_tail_started = now;
}

bool rgb_ble_bridge_process_record(uint16_t keycode, keyrecord_t *record) {
    (void)keycode;
    if (record->event.key.row != RGB_BLE_ARM_ROW || record->event.key.col != RGB_BLE_ARM_COL) return true;
    if (!record->event.pressed && arm_key_consumed) {
        arm_key_consumed = false;
        return false;
    }
    if (record->event.pressed && get_transport() == TRANSPORT_BLUETOOTH &&
        matrix_is_on(RGB_BLE_FN_ROW, RGB_BLE_FN_COL)) {
        arm_key_consumed = true;
        return false;
    }
    return true;
}

static void apply_command(const ble_rgb_command_t *command) {
#if defined(KEYCHRON_RGB_ENABLE) && defined(RETAIL_DEMO_ENABLE)
    /* Otherwise retail_demo_task() would immediately replace the requested
     * mode with MIXED_RGB. Leave the saved demo setting untouched. */
    extern uint8_t retail_demo_enable;
    retail_demo_enable = 0;
#endif
    if (command->mode == 0u) {
        rgb_matrix_disable_noeeprom();
        return;
    }
    /* Parser validation is the primary bound check; retain a defensive guard. */
    if (command->mode > BLE_RGB_MODE_MAX) return;
    const uint8_t value = (uint8_t)(((uint16_t)command->value * RGB_MATRIX_MAXIMUM_BRIGHTNESS) / 255u);
    /* The atomic API also protects HSV/speed from Keychron's EEPROM reload
     * throughout every chunk of the first render after a mode transition. */
    const uint8_t speed = command->version >= 2u ? command->speed : rgb_matrix_get_speed();
    rgb_matrix_set_config_noeeprom(qmk_effects[command->mode], command->hue,
                                   command->saturation, value, speed);
}

bool rgb_ble_bridge_led_update(led_t led_state) {
    if (!bluetooth_connected()) {
        reset_listener();
        return true;
    }
    sync_listener();
    const uint32_t now = timer_read32();
    const bool was_armed = decoder.armed;
    const bool was_receiving = ble_rgb_receiving(&decoder);
    if (!decoder.has_symbol) candidate_led_mask = previous_led_mask;
    ble_rgb_command_t command;
    if (ble_rgb_feed(&decoder, now, led_state.raw, &command)) {
        /* v3 mutations run in matrix_scan, never inside the LED callback. */
        pending_command_valid = command.version == 3u;
        if (pending_command_valid) pending_command = command;
        else apply_command(&command);
    }
    if (!was_armed && !was_receiving && ble_rgb_receiving(&decoder)) {
        original_led_mask = candidate_led_mask;
        indicator_tail = false;
    }
    if ((was_armed && !decoder.armed) || (was_receiving && !ble_rgb_receiving(&decoder))) start_indicator_tail(now);
    previous_led_mask = led_state.raw;
    return true;
}

void rgb_ble_bridge_matrix_scan(void) {
    const uint32_t now = timer_read32();
    const bool arm_down = matrix_is_on(RGB_BLE_ARM_ROW, RGB_BLE_ARM_COL);
    const bool fn_down = matrix_is_on(RGB_BLE_FN_ROW, RGB_BLE_FN_COL);
    if (!bluetooth_connected()) {
        reset_listener();
        hold_pending = false;
        arm_key_was_down = arm_down;
        return;
    }
    sync_listener();
    const bool was_armed = decoder.armed;
    const bool was_receiving = ble_rgb_receiving(&decoder);
    ble_rgb_tick(&decoder, now);
    if ((was_armed && !decoder.armed) || (was_receiving && !ble_rgb_receiving(&decoder))) start_indicator_tail(now);
    if (pending_command_valid) {
        pending_command_valid = false;
        apply_command(&pending_command);
        if (pending_command.command == BLE_RGB_CMD_SAVE_STATE) {
            rgb_matrix_save_lighting();
#if defined(KEYCHRON_RGB_ENABLE) && defined(RETAIL_DEMO_ENABLE)
            extern void rgb_save_retail_demo_if_changed(void);
            rgb_save_retail_demo_if_changed();
#endif
        }
    }
    if (indicator_tail && (uint32_t)(now - indicator_tail_started) >= RGB_BLE_INDICATOR_TAIL_MS) indicator_tail = false;

    /* Fn must already be held when the graphic key is pressed. A continuous
     * hold toggles only once; releasing either key cancels a pending hold. */
    if (arm_down && !arm_key_was_down && fn_down) {
        hold_pending = true;
        hold_started = now;
    }
    if (!arm_down || !fn_down) hold_pending = false;
    if (hold_pending && (uint32_t)(now - hold_started) >= RGB_BLE_HOLD_MS) {
        hold_pending = false;
        if (decoder.armed) {
            ble_rgb_disarm(&decoder);
            start_indicator_tail(now);
        } else {
            original_led_mask = host_keyboard_led_state().raw;
            indicator_tail = false;
            ble_rgb_arm(&decoder, now, original_led_mask);
        }
    }
    arm_key_was_down = arm_down;
}

/* Filter only the two data bits for the existing Keychron OS renderers.
 * Their configured colors, disable flags, USB suspension and other indicators
 * remain intact. The hook is installed by apply-qmk-patch.py. */
led_t keychron_filter_os_indicator_state(led_t state) {
    if (get_transport() == TRANSPORT_BLUETOOTH && (decoder.armed || ble_rgb_receiving(&decoder) || indicator_tail)) {
        state.raw = (uint8_t)((state.raw & ~3u) | (original_led_mask & 3u));
    }
    return state;
}
