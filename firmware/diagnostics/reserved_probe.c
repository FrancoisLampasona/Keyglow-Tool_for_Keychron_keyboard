/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "reserved_probe.h"
#include <string.h>

uint16_t kg_probe_crc16(const uint8_t *bytes, size_t length) {
    uint16_t crc = UINT16_C(0xffff);
    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)((uint16_t)bytes[i] << 8);
        for (uint8_t bit = 0; bit < 8; ++bit)
            crc = (uint16_t)((crc & UINT16_C(0x8000)) ? (uint16_t)(crc << 1) ^ UINT16_C(0x1021) : (uint16_t)(crc << 1));
    }
    return crc;
}

void kg_probe_init(kg_probe_t *probe) { memset(probe, 0, sizeof(*probe)); }

bool kg_probe_active(const kg_probe_t *probe) {
    return probe->state >= KG_PROBE_HOLDING && probe->state <= KG_PROBE_SENDING;
}

static void reset_parser(kg_probe_t *probe) {
    probe->magic_window = 0;
    probe->magic_symbols = 0;
    probe->frame_index = 0;
    probe->byte_symbols = 0;
    probe->accumulator = 0;
    probe->collecting = false;
    probe->has_symbol = false;
}

void kg_probe_abort(kg_probe_t *probe, kg_probe_abort_t reason) {
    if (!kg_probe_active(probe)) return;
    probe->state = KG_PROBE_ABORTED;
    probe->last_abort = reason;
    ++probe->aborts;
    reset_parser(probe);
}

void kg_probe_key_event(kg_probe_t *probe, bool is_chord_key, bool pressed) {
    if (!pressed || !kg_probe_active(probe)) return;
    if (!is_chord_key || probe->state >= KG_PROBE_WAIT_CHALLENGE)
        kg_probe_abort(probe, KG_PROBE_ABORT_KEY);
}

static bool clear_for_data(kg_probe_t *probe, const kg_probe_input_t *input) {
    if (!input->connected) kg_probe_abort(probe, KG_PROBE_ABORT_LINK);
    else if (input->fn_down || input->arm_down || input->other_key_down) kg_probe_abort(probe, KG_PROBE_ABORT_KEY);
    else if (!input->logical_idle) kg_probe_abort(probe, KG_PROBE_ABORT_LOGICAL_REPORT);
    else if (!input->battery_ok) kg_probe_abort(probe, KG_PROBE_ABORT_BATTERY);
    return probe->state != KG_PROBE_ABORTED;
}

void kg_probe_feed_led(kg_probe_t *probe, const kg_probe_input_t *input) {
    if (probe->state != KG_PROBE_WAIT_CHALLENGE) return;
    if (!clear_for_data(probe, input)) return;
    if ((uint32_t)(input->now - probe->phase_started) >= KG_PROBE_WINDOW_MS) {
        kg_probe_abort(probe, KG_PROBE_ABORT_TIMEOUT);
        return;
    }
    if (probe->has_symbol && (uint32_t)(input->now - probe->last_symbol_at) >= KG_PROBE_SYMBOL_TIMEOUT_MS)
        reset_parser(probe);
    const uint8_t clock = (uint8_t)((input->led_mask >> 2) & 1u);
    if (clock == probe->last_clock) return;
    probe->last_clock = clock;
    probe->last_symbol_at = input->now;
    probe->has_symbol = true;
    const uint8_t symbol = input->led_mask & 3u;
    if (!probe->collecting) {
        probe->magic_window = (probe->magic_window << 2) | symbol;
        if (probe->magic_symbols < 16u) ++probe->magic_symbols;
        if (probe->magic_symbols == 16u && probe->magic_window == UINT32_C(0x4b505242)) {
            const uint8_t magic[] = {0x4b, 0x50, 0x52, 0x42};
            memcpy(probe->frame, magic, sizeof(magic));
            probe->frame_index = 4;
            probe->collecting = true;
        }
        return;
    }
    probe->accumulator = (uint8_t)((probe->accumulator << 2) | symbol);
    if (++probe->byte_symbols != 4u) return;
    probe->frame[probe->frame_index++] = probe->accumulator;
    probe->accumulator = 0;
    probe->byte_symbols = 0;
    if (probe->frame_index != KG_PROBE_FRAME_SIZE) return;
    const uint16_t crc = (uint16_t)((uint16_t)probe->frame[11] << 8) | probe->frame[12];
    if (probe->frame[4] != 1u || probe->frame[5] != 1u || probe->frame[10] != 0u || crc != kg_probe_crc16(probe->frame, 11u)) {
        ++probe->invalid_frames;
        reset_parser(probe);
        return;
    }
    const uint8_t response_prefix[] = {0x4b, 0x50, 0x41, 0x4b, 1, 0};
    memcpy(probe->response, response_prefix, sizeof(response_prefix));
    memcpy(probe->response + 6, probe->frame + 6, 4);
    probe->response[10] = 0;
    const uint16_t response_crc = kg_probe_crc16(probe->response, 11u);
    probe->response[11] = (uint8_t)(response_crc >> 8);
    probe->response[12] = (uint8_t)response_crc;
    probe->response_symbol = 0;
    probe->phase_started = input->now;
    probe->quiet_started = input->now;
    probe->state = KG_PROBE_SETTLING;
    ++probe->challenges;
    reset_parser(probe);
}

bool kg_probe_tick(kg_probe_t *probe, const kg_probe_input_t *input, uint8_t report[8]) {
    memset(report, 0, 8);
    const bool fresh_chord = input->arm_down && !probe->previous_arm && input->fn_down && probe->previous_fn;
    probe->previous_fn = input->fn_down;
    probe->previous_arm = input->arm_down;
    if (!input->connected) {
        kg_probe_abort(probe, KG_PROBE_ABORT_LINK);
        return false;
    }
    if (!kg_probe_active(probe)) {
        if (fresh_chord && !input->other_key_down && input->battery_ok) {
            probe->state = KG_PROBE_HOLDING;
            probe->last_abort = KG_PROBE_ABORT_NONE;
            probe->phase_started = input->now;
            ++probe->attempts;
        }
        return false;
    }
    if (input->other_key_down) { kg_probe_abort(probe, KG_PROBE_ABORT_KEY); return false; }
    if (!input->battery_ok) { kg_probe_abort(probe, KG_PROBE_ABORT_BATTERY); return false; }
    if (probe->state == KG_PROBE_HOLDING) {
        if (!input->fn_down || !input->arm_down) kg_probe_abort(probe, KG_PROBE_ABORT_CHORD);
        else if ((uint32_t)(input->now - probe->phase_started) >= KG_PROBE_HOLD_MS) {
            probe->state = KG_PROBE_WAIT_RELEASE;
            probe->phase_started = input->now;
        }
        return false;
    }
    if (probe->state == KG_PROBE_WAIT_RELEASE) {
        if ((uint32_t)(input->now - probe->phase_started) >= KG_PROBE_RELEASE_MS) kg_probe_abort(probe, KG_PROBE_ABORT_TIMEOUT);
        else if (!input->fn_down && !input->arm_down) {
            probe->state = KG_PROBE_WAIT_CHALLENGE;
            probe->phase_started = input->now;
            reset_parser(probe);
            probe->last_clock = (uint8_t)((input->led_mask >> 2) & 1u);
        }
        return false;
    }
    if (!clear_for_data(probe, input)) return false;
    if (probe->state == KG_PROBE_WAIT_CHALLENGE) {
        if ((uint32_t)(input->now - probe->phase_started) >= KG_PROBE_WINDOW_MS) kg_probe_abort(probe, KG_PROBE_ABORT_TIMEOUT);
        return false;
    }
    if (probe->state == KG_PROBE_SETTLING) {
        if ((uint32_t)(input->now - probe->phase_started) >= KG_PROBE_RELEASE_MS) {
            kg_probe_abort(probe, KG_PROBE_ABORT_TIMEOUT); return false;
        }
        if (!input->queue_idle) probe->quiet_started = input->now;
        if ((uint32_t)(input->now - probe->quiet_started) < KG_PROBE_SETTLE_MS) return false;
        probe->state = KG_PROBE_SENDING;
    } else {
        if (!input->queue_idle) { kg_probe_abort(probe, KG_PROBE_ABORT_QUEUE); return false; }
        if ((uint32_t)(input->now - probe->last_report_at) >= KG_PROBE_MAX_REPORT_GAP_MS) {
            kg_probe_abort(probe, KG_PROBE_ABORT_TIMEOUT); return false;
        }
        if ((uint32_t)(input->now - probe->last_report_at) < KG_PROBE_REPORT_MS) return false;
    }
    if (probe->response_symbol < KG_PROBE_RESPONSE_SYMBOLS) {
        const uint8_t index = probe->response_symbol;
        const uint8_t byte = probe->response[index / 2u];
        report[1] = (uint8_t)((index & 1u ? 0x90u : 0x80u) | ((index & 1u ? byte : byte >> 4) & 15u));
        ++probe->response_symbol;
    } else {
        probe->state = KG_PROBE_DONE;
        ++probe->completions;
    }
    probe->last_report_at = input->now;
    ++probe->reports;
    return true;
}

static void put32(uint8_t *data, uint32_t value) {
    data[0] = (uint8_t)(value >> 24); data[1] = (uint8_t)(value >> 16);
    data[2] = (uint8_t)(value >> 8); data[3] = (uint8_t)value;
}

void kg_probe_status(const kg_probe_t *probe, bool usb, uint8_t *data, uint8_t length) {
    if (data == NULL || length == 0u) return;
    if (!usb || length != 32u || data[0] != 0x08u || data[1] != 0x4bu || data[2] != 0x50u) {
        data[0] = 0xff;
        return;
    }
    memset(data + 3, 0, 29);
    data[3] = 1;
    data[4] = (uint8_t)probe->state;
    data[5] = (uint8_t)probe->last_abort;
    data[6] = probe->response_symbol;
    put32(data + 8, probe->attempts);
    put32(data + 12, probe->challenges);
    put32(data + 16, probe->reports);
    put32(data + 20, probe->completions);
    put32(data + 24, probe->aborts);
    put32(data + 28, probe->invalid_frames);
}
