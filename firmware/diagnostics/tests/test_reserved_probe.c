/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "reserved_probe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static kg_probe_t probe;
static kg_probe_input_t in;
static uint8_t report[8];

static void fresh(uint32_t now) {
    kg_probe_init(&probe);
    in = (kg_probe_input_t){.now = now, .connected = true, .logical_idle = true, .queue_idle = true, .battery_ok = true};
}
static bool tick(uint32_t elapsed) { in.now += elapsed; return kg_probe_tick(&probe, &in, report); }
static void hold(void) {
    in.fn_down = true; CHECK(!tick(1));
    in.arm_down = true; CHECK(!tick(1)); CHECK(probe.state == KG_PROBE_HOLDING);
    CHECK(!tick(KG_PROBE_HOLD_MS)); CHECK(probe.state == KG_PROBE_WAIT_RELEASE);
}
static void arm(void) {
    hold(); in.fn_down = false; in.arm_down = false;
    CHECK(!tick(1)); CHECK(probe.state == KG_PROBE_WAIT_CHALLENGE);
}
static void frame(uint8_t bytes[13], const uint8_t nonce[4]) {
    const uint8_t prefix[] = {0x4b, 0x50, 0x52, 0x42, 1, 1};
    memcpy(bytes, prefix, sizeof(prefix)); memcpy(bytes + 6, nonce, 4); bytes[10] = 0;
    uint16_t crc = kg_probe_crc16(bytes, 11); bytes[11] = (uint8_t)(crc >> 8); bytes[12] = (uint8_t)crc;
}
static void feed(const uint8_t bytes[13]) {
    for (unsigned i = 0; i < 13; ++i) for (int shift = 6; shift >= 0; shift -= 2) {
        in.now += 80;
        in.led_mask = (uint8_t)(((in.led_mask ^ 4u) & 4u) | ((bytes[i] >> shift) & 3u));
        kg_probe_feed_led(&probe, &in);
        CHECK(!tick(0));
    }
}
static void challenge(void) {
    uint8_t bytes[13]; const uint8_t nonce[] = {0, 0x11, 0xaa, 0xff};
    frame(bytes, nonce); feed(bytes); CHECK(probe.state == KG_PROBE_SETTLING);
}
static void complete(void) {
    uint8_t decoded[13] = {0};
    CHECK(!tick(KG_PROBE_SETTLE_MS - 1)); CHECK(tick(1));
    for (unsigned i = 0; i < 26; ++i) {
        if (i) { CHECK(!tick(KG_PROBE_REPORT_MS - 1)); CHECK(tick(1)); }
        CHECK((report[1] & 0xf0u) == (i & 1u ? 0x90u : 0x80u));
        for (unsigned j = 0; j < 8; ++j) if (j != 1) CHECK(report[j] == 0);
        decoded[i / 2] = (uint8_t)((decoded[i / 2] << 4) | (report[1] & 15u));
    }
    const uint8_t prefix[] = {0x4b, 0x50, 0x41, 0x4b, 1, 0, 0, 0x11, 0xaa, 0xff, 0};
    CHECK(memcmp(decoded, prefix, sizeof(prefix)) == 0);
    CHECK(kg_probe_crc16(decoded, 11) == (((uint16_t)decoded[11] << 8) | decoded[12]));
    CHECK(tick(KG_PROBE_REPORT_MS));
    for (unsigned j = 0; j < 8; ++j) CHECK(report[j] == 0);
    CHECK(probe.state == KG_PROBE_DONE && probe.reports == 27 && probe.completions == 1);
    CHECK(!tick(10000));
}
static void progress(kg_probe_state_t state) {
    fresh(100); hold();
    if (state == KG_PROBE_HOLDING) { probe.state = KG_PROBE_HOLDING; return; }
    if (state == KG_PROBE_WAIT_RELEASE) return;
    in.fn_down = false; in.arm_down = false; CHECK(!tick(1));
    if (state == KG_PROBE_WAIT_CHALLENGE) return;
    challenge();
    if (state == KG_PROBE_SETTLING) return;
    CHECK(tick(KG_PROBE_SETTLE_MS)); CHECK(probe.state == KG_PROBE_SENDING);
}

int main(void) {
    fresh(100); uint8_t bytes[13]; const uint8_t nonce[] = {0, 0x11, 0xaa, 0xff}; frame(bytes, nonce);
    feed(bytes); CHECK(probe.state == KG_PROBE_IDLE && probe.reports == 0);
    in.arm_down = true; CHECK(!tick(1)); in.fn_down = true; CHECK(!tick(3000)); CHECK(probe.state == KG_PROBE_IDLE);
    fresh(100); in.fn_down = true; in.arm_down = true; CHECK(!tick(3000)); CHECK(probe.state == KG_PROBE_IDLE);
    fresh(100); in.fn_down = true; CHECK(!tick(1)); in.arm_down = true; CHECK(!tick(1));
    in.arm_down = false; CHECK(!tick(1999)); CHECK(probe.last_abort == KG_PROBE_ABORT_CHORD);
    fresh(100); hold(); CHECK(!tick(KG_PROBE_RELEASE_MS)); CHECK(probe.last_abort == KG_PROBE_ABORT_TIMEOUT);
    fresh(100); arm(); CHECK(!tick(KG_PROBE_WINDOW_MS)); feed(bytes); CHECK(probe.reports == 0);
    fresh(100); arm(); challenge(); complete(); feed(bytes); CHECK(probe.challenges == 1);
    fresh(UINT32_MAX - 1000u); arm(); challenge(); complete();

    for (unsigned field = 0; field < 4; ++field) {
        fresh(100); arm(); frame(bytes, nonce);
        const unsigned positions[] = {4, 5, 10, 12}; bytes[positions[field]] ^= 0x40;
        if (field != 3) { uint16_t crc = kg_probe_crc16(bytes, 11); bytes[11] = (uint8_t)(crc >> 8); bytes[12] = (uint8_t)crc; }
        feed(bytes); CHECK(probe.state == KG_PROBE_WAIT_CHALLENGE && probe.invalid_frames == 1 && probe.reports == 0);
        challenge(); complete();
    }
    fresh(100); arm(); frame(bytes, nonce); bytes[1] = 0x52; bytes[2] = 0x47;
    feed(bytes); CHECK(probe.challenges == 0 && probe.reports == 0); /* RGB magic cannot trigger a probe. */
    fresh(100); arm(); frame(bytes, nonce);
    for (unsigned i = 0; i < 16; ++i) {
        in.now += 80; in.led_mask = (uint8_t)(((in.led_mask ^ 4u) & 4u) | ((bytes[i / 4] >> (6 - 2 * (i % 4))) & 3u));
        kg_probe_feed_led(&probe, &in);
    }
    CHECK(probe.collecting); in.now += KG_PROBE_SYMBOL_TIMEOUT_MS; in.led_mask ^= 4;
    kg_probe_feed_led(&probe, &in); CHECK(!probe.collecting); challenge(); complete();

    for (kg_probe_state_t state = KG_PROBE_HOLDING; state <= KG_PROBE_SENDING; ++state) {
        progress(state); uint32_t reports = probe.reports;
        in.other_key_down = true; CHECK(!tick(100));
        CHECK(probe.state == KG_PROBE_ABORTED && probe.last_abort == KG_PROBE_ABORT_KEY && probe.reports == reports);
        in.other_key_down = false; CHECK(!tick(10000));
        progress(state); reports = probe.reports;
        in.connected = false; CHECK(!tick(1)); in.connected = true; CHECK(!tick(100));
        CHECK(probe.last_abort == KG_PROBE_ABORT_LINK && probe.reports == reports);
        progress(state); kg_probe_key_event(&probe, false, true);
        CHECK(probe.last_abort == KG_PROBE_ABORT_KEY); CHECK(!tick(100));
    }
    for (kg_probe_state_t state = KG_PROBE_WAIT_CHALLENGE; state <= KG_PROBE_SENDING; ++state) {
        progress(state); in.logical_idle = false; CHECK(!tick(100)); CHECK(probe.last_abort == KG_PROBE_ABORT_LOGICAL_REPORT);
        progress(state); in.fn_down = true; CHECK(!tick(100)); CHECK(probe.last_abort == KG_PROBE_ABORT_KEY);
        progress(state); in.arm_down = true; CHECK(!tick(100)); CHECK(probe.last_abort == KG_PROBE_ABORT_KEY);
        progress(state); kg_probe_key_event(&probe, true, true); CHECK(probe.last_abort == KG_PROBE_ABORT_KEY);
        progress(state); in.battery_ok = false; CHECK(!tick(100)); CHECK(probe.last_abort == KG_PROBE_ABORT_BATTERY);
    }
    progress(KG_PROBE_SETTLING); in.queue_idle = false; CHECK(!tick(600));
    in.queue_idle = true; CHECK(!tick(599)); CHECK(tick(1));
    in.queue_idle = false; CHECK(!tick(100)); CHECK(probe.last_abort == KG_PROBE_ABORT_QUEUE);
    progress(KG_PROBE_SENDING); CHECK(!tick(1000)); CHECK(probe.last_abort == KG_PROBE_ABORT_TIMEOUT);
    progress(KG_PROBE_SETTLING); in.queue_idle = false; CHECK(!tick(5000)); CHECK(probe.last_abort == KG_PROBE_ABORT_TIMEOUT);

    fresh(100); arm(); challenge(); complete();
    uint8_t status[32] = {8, 0x4b, 0x50}; kg_probe_t unchanged = probe;
    kg_probe_status(&probe, true, status, sizeof(status));
    CHECK(status[0] == 8 && status[3] == 1 && status[4] == KG_PROBE_DONE && status[6] == 26);
    CHECK(status[11] == 1 && status[15] == 1 && status[19] == 27 && status[23] == 1 && status[27] == 0);
    CHECK(memcmp(&unchanged, &probe, sizeof(probe)) == 0);
    kg_probe_status(&probe, false, status, sizeof(status)); CHECK(status[0] == 0xff);
    status[0] = 7; kg_probe_status(&probe, true, status, sizeof(status)); CHECK(status[0] == 0xff);
    uint8_t short_status = 8; kg_probe_status(&probe, true, &short_status, 1); CHECK(short_status == 0xff);
    kg_probe_status(&probe, true, NULL, 0);
    printf("Reserved probe core: %u assertions passed; no device access.\n", checks);
    return 0;
}
