/* Example only: merge into the existing keymap.c; do not compile as another
 * translation unit if these callbacks already exist in the keymap.
 * Also compile qmk_responsive_idle.c for the optional 1092-minute preset;
 * it adds a veto to the original Q6 lpm_is_kb_idle() through q6_lpm_is_idle_user,
 * preserving the board's power-on and backlight indicator checks. */
#include "qmk_rgb_ble_bridge.h"

bool process_record_user(uint16_t keycode, keyrecord_t *record) {
    if (!rgb_ble_bridge_process_record(keycode, record)) return false;
    /* Preserve any existing process_record_user logic here. */
    return true;
}

bool led_update_user(led_t led_state) {
    if (!rgb_ble_bridge_led_update(led_state)) return false;
    /* Preserve any existing led_update_user logic here. */
    return true;
}

void matrix_scan_user(void) {
    rgb_ble_bridge_matrix_scan();
    /* Preserve any existing matrix_scan_user logic here. */
}
