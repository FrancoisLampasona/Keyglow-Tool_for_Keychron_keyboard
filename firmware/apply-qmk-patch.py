#!/usr/bin/env python3
"""Install RGB/power hooks and a bounded LKBT51 SPI receive fix in pinned QMK.

No firmware compilation, reset, flash or hardware access. Validate all edits
before writing any file. --check reports the edits without changing the tree.
"""
import argparse
import pathlib
import subprocess

PIN = "2b493ff95f2665db719b1e95c91babb5036e72f3"
HOOK = "keychron_filter_os_indicator_state"
RGB_API_DECLARATION = "void rgb_matrix_set_config_noeeprom(uint8_t mode, uint16_t hue, uint8_t sat, uint8_t val, uint8_t speed);"
RGB_API_IMPLEMENTATION = """/* Apply a complete volatile state in one task turn. The first render may span
 * several chunks; keep its HSV/speed until rgb_task_flush completes that frame. */
void rgb_matrix_set_config_noeeprom(uint8_t mode, uint16_t hue, uint8_t sat, uint8_t val, uint8_t speed) {
    if (mode < 1 || mode >= RGB_MATRIX_EFFECT_MAX) return;
    rgb_matrix_enable_noeeprom();
    rgb_matrix_mode_noeeprom(mode);
    rgb_matrix_sethsv_noeeprom(hue, sat, val);
    rgb_matrix_set_speed_noeeprom(speed);
    rgb_volatile_config_pending = true;
    rgb_task_state = STARTING;
}

"""


RGB_SAVE_DECLARATION = "void rgb_matrix_save_lighting(void);"
RGB_SAVE_IMPLEMENTATION = """/* Save only the lighting fields owned by the RGB command. Preserve stored flags
 * and reserved bytes, and avoid writes when the requested state is unchanged. */
void rgb_matrix_save_lighting(void) {
    rgb_config_t saved;
    eeprom_read_block(&saved, EECONFIG_RGB_MATRIX, sizeof(saved));
    rgb_config_t desired = saved;
    desired.enable = rgb_matrix_config.enable;
    desired.mode = rgb_matrix_config.mode;
    desired.hsv = rgb_matrix_config.hsv;
    desired.speed = rgb_matrix_config.speed;
    if (memcmp(&saved, &desired, sizeof(saved)) != 0) {
        eeconfig_update_rgb_matrix(&desired);
    }
}

"""
RETAIL_SAVE_IMPLEMENTATION = """/* A Bluetooth save must also survive a previously saved retail-demo flag.
 * This changes only that byte, without saving per-key, Mix or OS indicators. */
void rgb_save_retail_demo_if_changed(void) {
    uint8_t saved;
    eeprom_read_block(&saved, (uint8_t *)(OFFSET_RETAIL_DEMO), sizeof(saved));
    if (saved != retail_demo_enable) rgb_save_retail_demo();
}

"""


def replace_once(text, old, new):
    if new in text:
        return text
    if text.count(old) != 1:
        raise ValueError(f"Unexpected source; expected one occurrence of {old!r}")
    return text.replace(old, new, 1)


def filter_renderer(text, signature, next_function):
    start = text.index(signature)
    end = text.index(next_function, start)
    region = text[start:end]
    declaration = f"\n    const led_t led_state = {HOOK}(host_keyboard_led_state());"
    if declaration in region:
        if region.count("host_keyboard_led_state()") != 1:
            raise ValueError("Partially patched indicator renderer")
        return text
    if region.count("host_keyboard_led_state()") < 2:
        raise ValueError("Expected Caps/Num source reads missing")
    region = region.replace("host_keyboard_led_state()", "led_state")
    region = region.replace(signature, signature + declaration, 1)
    return text[:start] + region + text[end:]


def patch_rgb_source(text):
    text = replace_once(text, "// internals\n", "// internals\nstatic bool rgb_volatile_config_pending = false;\n")
    old_reload = """        rgb_config_t rgb_cfg;
        eeprom_read_block(&rgb_cfg, EECONFIG_RGB_MATRIX, sizeof(rgb_cfg));
        rgb_matrix_config.hsv = rgb_cfg.hsv;
        rgb_matrix_config.speed = rgb_cfg.speed;"""
    new_reload = """        if (!rgb_volatile_config_pending) {
            rgb_config_t rgb_cfg;
            eeprom_read_block(&rgb_cfg, EECONFIG_RGB_MATRIX, sizeof(rgb_cfg));
            rgb_matrix_config.hsv = rgb_cfg.hsv;
            rgb_matrix_config.speed = rgb_cfg.speed;
        }"""
    text = replace_once(text, old_reload, new_reload)
    text = replace_once(text, "    rgb_last_enable = rgb_matrix_config.enable;\n",
                        "    rgb_last_enable = rgb_matrix_config.enable;\n    rgb_volatile_config_pending = false;\n")
    for signature in ["void rgb_matrix_mode_eeprom_helper(uint8_t mode, bool write_to_eeprom) {",
                      "void rgb_matrix_disable_noeeprom(void) {",
                      "void rgb_matrix_toggle_eeprom_helper(bool write_to_eeprom) {"]:
        text = replace_once(text, signature, signature + "\n    rgb_volatile_config_pending = false;")
    anchor = "void rgb_matrix_set_speed(uint8_t speed) {"
    if RGB_API_IMPLEMENTATION not in text:
        text = replace_once(text, anchor, RGB_API_IMPLEMENTATION + anchor)
    if RGB_SAVE_IMPLEMENTATION not in text:
        text = replace_once(text, anchor, RGB_SAVE_IMPLEMENTATION + anchor)
    return text


def patch_battery_source(text):
    text = replace_once(text, "static uint16_t voltage                  = FULL_VOLTAGE_VALUE;",
                        "static uint16_t voltage                  = FULL_VOLTAGE_VALUE;\n"
                        "static bool voltage_has_valid_reading = false;")
    text = replace_once(text, "void battery_init(void) {",
                        "void battery_init(void) {\n    voltage_has_valid_reading = false;")
    text = replace_once(text, "void battery_set_voltage(uint16_t value) {\n    voltage = value;\n}",
                        "void battery_set_voltage(uint16_t value) {\n    voltage = value;\n"
                        "    voltage_has_valid_reading = value > 0 && value <= FULL_VOLTAGE_VALUE + 300u;\n}")
    anchor = "uint16_t battery_get_voltage(void) {"
    text = replace_once(text, anchor,
                        "/* The initial full-voltage default is not a measurement. */\n"
                        "bool battery_has_valid_reading(void) {\n    return voltage_has_valid_reading;\n}\n\n" + anchor)
    return text


def patch_wireless_source(text):
    anchor = "wt_state_t wireless_get_state(void) {"
    return replace_once(text, anchor,
                        "uint16_t wireless_get_connected_idle_timeout(void) {\n    return connected_idle_time;\n}\n\n" + anchor)


def patch_q6_source(text):
    original = """bool lpm_is_kb_idle(void) {
    return power_on_indicator_timer == 0 && !backlight_indicator_is_active();
}"""
    patched = """__attribute__((weak)) bool q6_lpm_is_idle_user(void) {
    return true;
}

bool lpm_is_kb_idle(void) {
    return power_on_indicator_timer == 0 && !backlight_indicator_is_active() && q6_lpm_is_idle_user();
}"""
    return replace_once(text, original, patched)


def patch_lkbt51_source(text):
    original = """void lkbt51_read(uint8_t* payload, uint8_t len) {
    uint8_t i;
    uint8_t pkt[PACKET_MAX_LEN] = {0};
    memset(pkt, 0, PACKET_MAX_LEN);"""
    patched = """void lkbt51_read(uint8_t* payload, uint8_t len) {
    /* len excludes the four SPI command bytes. Keep the existing transfer
     * length (4 + len), with room for every transmitted and received byte. */
    if (len > PACKET_MAX_LEN) return;
    uint8_t i;
    uint8_t pkt[PACKET_MAX_LEN + 4u] = {0};
    memset(pkt, 0, sizeof(pkt));"""
    text = replace_once(text, original, patched)
    original_caller = """        uint8_t buf[BUFFER_SIZE] = {0};
        lkbt51_read(buf, expect_len);"""
    patched_caller = """        /* The extra SPI command bytes are transferred too. BUFFER_SIZE
         * remains the parser limit; only the receive allocation grows. */
        uint8_t buf[BUFFER_SIZE + VALID_DATA_START_INDEX] = {0};
        lkbt51_read(buf, expect_len);"""
    return replace_once(text, original_caller, patched_caller)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("qmk_root", type=pathlib.Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.qmk_root.resolve()
    actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if actual != PIN:
        raise SystemExit(f"Refusing a different source revision: {actual}; expected {PIN}")
    common = root / "keyboards/keychron/common"
    paths = [common / "backlit_indicator.h", common / "backlit_indicator.c", common / "rgb/keychron_rgb.c",
             root / "quantum/rgb_matrix/rgb_matrix.c", root / "quantum/rgb_matrix/rgb_matrix.h",
             common / "wireless/battery.c", common / "wireless/battery.h",
             common / "wireless/wireless.c", common / "wireless/wireless.h",
             root / "keyboards/keychron/q6_max/q6_max.c", common / "wireless/lkbt51.c"]
    before = [path.read_text() for path in paths]
    after = list(before)
    after[0] = replace_once(after[0], "#pragma once", '#pragma once\n#include "led.h"')
    after[0] = replace_once(after[0], "void os_state_indicate(void);",
                            f"led_t {HOOK}(led_t state);\nvoid os_state_indicate(void);")
    signature = "__attribute__((weak)) void os_state_indicate(void) {"
    hook = (f"__attribute__((weak)) led_t {HOOK}(led_t state) {{\n"
            "    return state;\n}\n\n" + signature)
    after[1] = replace_once(after[1], signature, hook)
    after[1] = filter_renderer(after[1], signature, "\nvoid backlight_indicator_init(")
    after[2] = filter_renderer(after[2], "void os_state_indicate(void) {", "\nvoid rgb_matrix_none_indicators(")
    after[2] = replace_once(after[2], "static bool rgb_get_version(uint8_t *data) {",
                            RETAIL_SAVE_IMPLEMENTATION + "static bool rgb_get_version(uint8_t *data) {")
    after[3] = patch_rgb_source(after[3])
    after[4] = replace_once(after[4], "void        rgb_matrix_set_speed_noeeprom(uint8_t speed);",
                            "void        rgb_matrix_set_speed_noeeprom(uint8_t speed);\n" + RGB_API_DECLARATION)
    after[4] = replace_once(after[4], RGB_API_DECLARATION, RGB_API_DECLARATION + "\n" + RGB_SAVE_DECLARATION)
    after[5] = patch_battery_source(after[5])
    after[6] = replace_once(after[6], "uint16_t battery_get_voltage(void);",
                           "uint16_t battery_get_voltage(void);\nbool     battery_has_valid_reading(void);")
    after[7] = patch_wireless_source(after[7])
    after[8] = replace_once(after[8], "wt_state_t wireless_get_state(void);",
                           "wt_state_t wireless_get_state(void);\nuint16_t wireless_get_connected_idle_timeout(void);")
    after[9] = patch_q6_source(after[9])
    after[10] = patch_lkbt51_source(after[10])
    changed = [i for i in range(len(paths)) if before[i] != after[i]]
    for i in changed:
        print(("Would patch: " if args.check else "Patching: ") + str(paths[i].relative_to(root)))
    if not args.check:
        for i in changed:
            paths[i].write_text(after[i])
    if not changed:
        print("RGB/power hooks and LKBT51 SPI bounds fix already installed; no changes.")
    elif args.check:
        print("All transformations validated; no files changed.")


if __name__ == "__main__":
    main()
