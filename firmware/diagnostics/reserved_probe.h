/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef KEYGLOW_RESERVED_PROBE_H
#define KEYGLOW_RESERVED_PROBE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KG_PROBE_HOLD_MS 2000u
#define KG_PROBE_RELEASE_MS 5000u
#define KG_PROBE_WINDOW_MS 30000u
#define KG_PROBE_SYMBOL_TIMEOUT_MS 400u
#define KG_PROBE_SETTLE_MS 600u
#define KG_PROBE_REPORT_MS 100u
#define KG_PROBE_MAX_REPORT_GAP_MS 1000u
#define KG_PROBE_FRAME_SIZE 13u
#define KG_PROBE_RESPONSE_SYMBOLS 26u

typedef enum {
    KG_PROBE_IDLE, KG_PROBE_HOLDING, KG_PROBE_WAIT_RELEASE,
    KG_PROBE_WAIT_CHALLENGE, KG_PROBE_SETTLING, KG_PROBE_SENDING,
    KG_PROBE_DONE, KG_PROBE_ABORTED
} kg_probe_state_t;

typedef enum {
    KG_PROBE_ABORT_NONE, KG_PROBE_ABORT_KEY, KG_PROBE_ABORT_LINK,
    KG_PROBE_ABORT_LOGICAL_REPORT, KG_PROBE_ABORT_QUEUE,
    KG_PROBE_ABORT_TIMEOUT, KG_PROBE_ABORT_CHORD, KG_PROBE_ABORT_BATTERY
} kg_probe_abort_t;

typedef struct {
    uint32_t now;
    bool connected, fn_down, arm_down, other_key_down;
    bool logical_idle, queue_idle, battery_ok;
    uint8_t led_mask;
} kg_probe_input_t;

typedef struct {
    kg_probe_state_t state;
    kg_probe_abort_t last_abort;
    uint32_t attempts, challenges, reports, completions, aborts, invalid_frames;
    uint32_t phase_started, quiet_started, last_report_at;
    bool previous_fn, previous_arm;
    uint8_t response[KG_PROBE_FRAME_SIZE], response_symbol;
    uint8_t last_clock, magic_symbols, frame_index, byte_symbols, accumulator;
    bool collecting, has_symbol;
    uint32_t magic_window, last_symbol_at;
    uint8_t frame[KG_PROBE_FRAME_SIZE];
} kg_probe_t;

void kg_probe_init(kg_probe_t *probe);
bool kg_probe_active(const kg_probe_t *probe);
void kg_probe_abort(kg_probe_t *probe, kg_probe_abort_t reason);
void kg_probe_key_event(kg_probe_t *probe, bool is_chord_key, bool pressed);
void kg_probe_feed_led(kg_probe_t *probe, const kg_probe_input_t *input);
/* True means one all-idle keyboard report is ready; only its reserved byte may differ. */
bool kg_probe_tick(kg_probe_t *probe, const kg_probe_input_t *input, uint8_t report[8]);
uint16_t kg_probe_crc16(const uint8_t *bytes, size_t length);
/* Read-only diagnostic response. Unrecognized commands are returned as VIA unhandled. */
void kg_probe_status(const kg_probe_t *probe, bool usb, uint8_t *data, uint8_t length);
#endif
