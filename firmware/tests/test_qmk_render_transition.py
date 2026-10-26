#!/usr/bin/env python3
"""Compile the actual pinned render/reload/API snippets against a fake EEPROM.

All source patching happens in memory; the QMK checkout and hardware are untouched.
"""
import importlib.util
import pathlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
FIRMWARE = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("qmk_patch", FIRMWARE / "apply-qmk-patch.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)
qmk = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else FIRMWARE.parent / "build/qmk-firmware"
source = (qmk / "quantum/rgb_matrix/rgb_matrix.c").read_text()
source = patch.patch_rgb_source(source)
assert patch.patch_rgb_source(source) == source, "RGB patch must be idempotent"


def function(name):
    import re
    found = re.search(r"^(?:static )?void " + re.escape(name) + r"\([^\n]*\) \{", source, re.MULTILINE)
    if not found:
        raise AssertionError(f"Missing source function: {name}")
    level = 0
    for end in range(source.index("{", found.start()), len(source)):
        if source[end] == "{":
            level += 1
        elif source[end] == "}":
            level -= 1
            if level == 0:
                return source[found.start():end + 1]
    raise AssertionError(f"Unbalanced source function: {name}")


names = ["rgb_matrix_enable_noeeprom", "rgb_matrix_mode_eeprom_helper", "rgb_matrix_mode_noeeprom",
         "rgb_matrix_sethsv_eeprom_helper", "rgb_matrix_sethsv_noeeprom",
         "rgb_matrix_set_speed_eeprom_helper", "rgb_matrix_set_speed_noeeprom",
         "rgb_matrix_disable_noeeprom", "rgb_matrix_toggle_eeprom_helper", "rgb_matrix_toggle_noeeprom",
         "rgb_matrix_set_config_noeeprom", "rgb_matrix_save_lighting", "rgb_task_flush"]
functions = [function(name) for name in names]
# The reload/init preamble is the actual first part of rgb_task_render; animation
# code is replaced by a chunk counter so the same preamble runs for each chunk.
render = function("rgb_task_render").split("    if (rgb_effect_params.flags", 1)[0]
render = render.replace("    bool rendering         = false;\n", "")
render += "    ++render_chunks;\n}\n"
preamble = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "RENDER FAIL %d: %s\n", __LINE__, #c); exit(1); } } while (0)
#define dprintf(...) ((void)0)
#define RGB_MATRIX_MAXIMUM_BRIGHTNESS 180
#define RGB_MATRIX_BRIGHTNESS_TURN_OFF_VAL 48
#define RGB_MATRIX_EFFECT_MAX 25
#define RGB_MATRIX_LED_COUNT 109
#define EECONFIG_RGB_MATRIX ((void *)&stored)
typedef struct { uint8_t h, s, v; } hsv_t;
typedef union {
    uint64_t raw;
    struct __attribute__((packed)) {
        uint8_t enable:2;
        uint8_t mode:6;
        hsv_t hsv;
        uint8_t speed, flags;
    };
} rgb_config_t;
enum { STARTING, SYNCING };
static rgb_config_t rgb_matrix_config, stored;
static uint8_t stored_demo, retail_demo_enable;
#define OFFSET_RETAIL_DEMO (&stored_demo)
static bool rgb_volatile_config_pending;
static uint8_t rgb_last_effect, rgb_last_enable;
static unsigned rgb_task_state, reads, writes, render_chunks, flushes;
static struct { bool init; } rgb_effect_params;
static uint8_t rgb_regions[RGB_MATRIX_LED_COUNT];
void eeprom_read_block(void *dst, const void *address, size_t size) {
    CHECK((address==&stored && size==sizeof(stored)) || (address==&stored_demo && size==1));
    memcpy(dst,address,size); ++reads;
}
void eeprom_write_byte(void *address, uint8_t value) { (void)address; (void)value; ++writes; }
void eeprom_write_block(const void *source, void *address, size_t size) {
    (void)source; (void)address; (void)size; ++writes;
}
void eeconfig_update_rgb_matrix(const rgb_config_t *desired) { stored=*desired; ++writes; }
void rgb_save_retail_demo(void) { stored_demo=retail_demo_enable; ++writes; }
void rgb_matrix_update_pwm_buffers(void) { ++flushes; }
void rgb_matrix_increase_val_helper(bool persistent) {
    rgb_matrix_config.hsv.v += 16;
    if (persistent) ++writes;
}
'''
main = r'''
static void expect(uint8_t mode, uint8_t hue, uint8_t value, uint8_t speed) {
    CHECK(rgb_matrix_config.enable == 1 && rgb_matrix_config.mode == mode);
    CHECK(rgb_matrix_config.hsv.h == hue && rgb_matrix_config.hsv.s == 255);
    CHECK(rgb_matrix_config.hsv.v == value && rgb_matrix_config.speed == speed);
}
static void render_full(uint8_t mode, uint8_t hue, uint8_t value, uint8_t speed) {
    unsigned previous_reads = reads;
    for (unsigned chunk = 0; chunk < 4; ++chunk) {
        rgb_task_render(mode);
        CHECK(rgb_volatile_config_pending);
        expect(mode, hue, value, speed);
        CHECK(reads == previous_reads);
    }
    rgb_task_flush(mode);
    CHECK(!rgb_volatile_config_pending && rgb_last_effect == mode);
    rgb_task_render(mode);
    CHECK(reads == previous_reads);
    expect(mode, hue, value, speed);
}
int main(void) {
    stored = (rgb_config_t){.enable=1, .mode=20, .hsv={0,255,170}, .speed=77};
    rgb_matrix_config = stored; rgb_last_effect=20; rgb_last_enable=1;
    memset(rgb_regions, 9, sizeof(rgb_regions));
    rgb_matrix_set_config_noeeprom(1,85,255,180,200);
    CHECK(rgb_task_state == STARTING && rgb_volatile_config_pending);
    render_full(1,85,180,200);
    for (unsigned i=0; i<sizeof(rgb_regions); ++i) CHECK(rgb_regions[i] == 0);

    /* Original manual mode transitions still reload saved HSV/speed. */
    rgb_matrix_mode_noeeprom(2); CHECK(!rgb_volatile_config_pending);
    unsigned previous_reads=reads;
    rgb_task_render(2); CHECK(reads == previous_reads+1);
    expect(2,0,170,77);
    rgb_task_render(2); CHECK(reads == previous_reads+2);
    rgb_task_flush(2);

    /* Same-mode updates retire the protection on the very next flush. */
    rgb_matrix_set_config_noeeprom(2,160,255,90,0);
    render_full(2,160,90,0);
    rgb_matrix_mode_noeeprom(3); rgb_task_render(3); expect(3,0,170,77); rgb_task_flush(3);

    /* OFF -> ON, minimum brightness and speed extremes stay volatile. */
    rgb_matrix_disable_noeeprom(); CHECK(!rgb_volatile_config_pending && !rgb_matrix_config.enable);
    rgb_task_render(0); rgb_task_flush(0);
    rgb_matrix_set_config_noeeprom(1,85,255,0,255);
    render_full(1,85,0,255);

    /* A manual change during an unfinished volatile frame cancels protection. */
    rgb_matrix_set_config_noeeprom(4,85,255,180,200);
    rgb_task_render(4); CHECK(rgb_volatile_config_pending);
    rgb_matrix_mode_noeeprom(5); CHECK(!rgb_volatile_config_pending);
    rgb_task_render(5); expect(5,0,170,77); rgb_task_flush(5);

    /* A new full state during the first frame replaces it without old values. */
    rgb_matrix_set_config_noeeprom(1,85,255,180,200);
    rgb_task_render(1);
    rgb_matrix_set_config_noeeprom(2,160,255,0,0);
    render_full(2,160,0,0);

    rgb_matrix_set_config_noeeprom(1,85,255,180,200);
    rgb_matrix_disable_noeeprom(); CHECK(!rgb_volatile_config_pending);
    rgb_task_render(0); rgb_task_flush(0);
    rgb_matrix_set_config_noeeprom(1,85,255,180,200);
    rgb_matrix_toggle_noeeprom(); CHECK(!rgb_volatile_config_pending);
    CHECK(!rgb_matrix_config.enable);
    rgb_matrix_set_config_noeeprom(RGB_MATRIX_EFFECT_MAX,85,255,180,200);
    CHECK(!rgb_volatile_config_pending && !rgb_matrix_config.enable);
    CHECK(writes == 0);
    CHECK(render_chunks >= 20 && flushes >= 8);
    /* v3 save stores only owned lighting fields, preserving EEPROM flags and
     * reserved bytes even if the live flags differ. Actual patched function. */
    stored.raw = UINT64_C(0xa55a550000000001);
    stored.enable=1; stored.mode=20; stored.hsv=(hsv_t){0,255,170}; stored.speed=77;
    stored.flags=0x55;
    rgb_matrix_config=stored; rgb_matrix_config.flags=0xaa;
    rgb_matrix_set_config_noeeprom(2,85,255,180,200);
    rgb_matrix_save_lighting(); CHECK(writes==1);
    CHECK(stored.enable==1 && stored.mode==2 && stored.hsv.h==85 && stored.hsv.s==255 && stored.hsv.v==180 && stored.speed==200);
    CHECK(stored.flags==0x55 && (stored.raw>>48)==0xa55a);
    rgb_matrix_save_lighting(); CHECK(writes==1); /* identical request skips write */
    /* A simulated restart uses saved state; first-render reload stays green. */
    memset(&rgb_matrix_config,0,sizeof(rgb_matrix_config));
    eeprom_read_block(&rgb_matrix_config,EECONFIG_RGB_MATRIX,sizeof(rgb_matrix_config));
    rgb_volatile_config_pending=false; rgb_last_effect=UINT8_MAX;
    rgb_task_render(2); expect(2,85,180,200); rgb_task_flush(2);
    rgb_matrix_disable_noeeprom(); rgb_matrix_save_lighting(); CHECK(writes==2 && stored.enable==0);
    memset(&rgb_matrix_config,0,sizeof(rgb_matrix_config));
    eeprom_read_block(&rgb_matrix_config,EECONFIG_RGB_MATRIX,sizeof(rgb_matrix_config));
    CHECK(!rgb_matrix_config.enable && rgb_matrix_config.mode==2);
    rgb_matrix_save_lighting(); CHECK(writes==2);
    rgb_matrix_set_config_noeeprom(2,170,255,0,0); rgb_matrix_save_lighting();
    CHECK(writes==3 && stored.enable==1 && stored.hsv.v==0 && stored.speed==0);
    stored_demo=1; retail_demo_enable=0;
    rgb_save_retail_demo_if_changed(); CHECK(writes==4 && stored_demo==0);
    rgb_save_retail_demo_if_changed(); CHECK(writes==4);
    CHECK(stored.flags==0x55 && (stored.raw>>48)==0xa55a);
    puts("PASS: actual QMK render and save snippets; volatile first-frame protection, persistent green Breathing/OFF/zero values after reload, stored flags/reserved preservation, duplicate-write suppression and targeted demo save.");
    return 0;
}
'''
prototypes = "\n".join(body.split(" {",1)[0]+";" for body in functions)
with tempfile.TemporaryDirectory(prefix="tastiera-render-test-") as temp:
    test_source = pathlib.Path(temp) / "test.c"
    executable = pathlib.Path(temp) / "test"
    test_source.write_text(preamble + prototypes + "\n" + "\n".join(functions) + "\n" + render + patch.RETAIL_SAVE_IMPLEMENTATION + main)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                    "-fsanitize=address,undefined", str(test_source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
