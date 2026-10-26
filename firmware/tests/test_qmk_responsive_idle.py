#!/usr/bin/env python3
"""Test the policy with real pinned battery getter/init snippets; no tree writes."""
import importlib.util
import pathlib
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
firmware = pathlib.Path(__file__).resolve().parents[1]
qmk = firmware.parent / "build/qmk-firmware"
spec = importlib.util.spec_from_file_location("qmk_patch", firmware / "apply-qmk-patch.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)
source = patch.patch_battery_source((qmk / "keyboards/keychron/common/wireless/battery.c").read_text())
assert patch.patch_battery_source(source) == source
wireless = patch.patch_wireless_source((qmk / "keyboards/keychron/common/wireless/wireless.c").read_text())
assert patch.patch_wireless_source(wireless) == wireless
board = patch.patch_q6_source((qmk / "keyboards/keychron/q6_max/q6_max.c").read_text())
assert patch.patch_q6_source(board) == board


def function(name, source=source):
    found = re.search(r"^(?:__attribute__\(\(weak\)\) )?(?:void|bool|uint16_t) " + re.escape(name) + r"\([^\n]*\) \{", source, re.MULTILINE)
    assert found, name
    level = 0
    for end in range(source.index("{", found.start()), len(source)):
        if source[end] == "{": level += 1
        elif source[end] == "}":
            level -= 1
            if level == 0: return source[found.start():end + 1]
    raise AssertionError(name)


with tempfile.TemporaryDirectory(prefix="tastiera-idle-test-") as temp:
    snippets = pathlib.Path(temp) / "battery.inc"
    snippets.write_text("static uint16_t voltage = FULL_VOLTAGE_VALUE;\n"
                        "static bool voltage_has_valid_reading = false;\nstatic uint8_t bat_state;\n" +
                        "\n".join(function(name) for name in ["battery_init", "battery_set_voltage",
                                                              "battery_get_voltage", "battery_has_valid_reading"]) +
                        "\nstatic uint32_t power_on_indicator_timer;\nstatic bool test_backlight_indicator;\n"
                        "bool backlight_indicator_is_active(void) { return test_backlight_indicator; }\n" +
                        function("q6_lpm_is_idle_user", board) + "\n" + function("lpm_is_kb_idle", board))
    executable = pathlib.Path(temp) / "test"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                    "-fsanitize=address,undefined", "-I"+str(firmware), "-I"+str(firmware / "tests/qmk_stub"),
                    '-DQMK_KEYBOARD_H="qmk_mock.h"', '-DQ6_BATTERY_TEST_SOURCE="'+str(snippets)+'"',
                    str(firmware / "qmk_responsive_idle.c"), str(firmware / "tests/test_qmk_responsive_idle.c"),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
