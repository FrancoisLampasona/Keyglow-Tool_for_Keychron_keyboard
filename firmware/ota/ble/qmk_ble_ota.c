/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "qmk_ble_ota.h"
#include "keyglow_ble_wire.h"
#include "ble_rgb_protocol.h"
#include "qmk_ota_adapter.h"
#include "action_util.h"
#include "battery.h"
#include "host.h"
#include "lkbt51.h"
#include "matrix.h"
#include "report_buffer.h"
#include "timer.h"
#include "transport.h"
#include "wireless.h"
#include <string.h>

#if !defined(LK_WIRELESS_ENABLE) || !defined(RGB_MATRIX_ENABLE)
#    error "BLE OTA is limited to the Q6 Max ISO LKBT51 build."
#endif

typedef enum { LINK_IDLE, LINK_ENGINE, LINK_SETTLING, LINK_SENDING, LINK_RECEIPT } link_phase;
static kg_ble_led_decoder decoder;
/* A side-effect-free outer-protocol discriminator. It prevents a literal KGOT
 * in valid RGB HSV/speed bytes from hijacking that already-started frame. */
static ble_rgb_decoder_t rgb_guard;
static link_phase phase;
static bool initialized, quarantine, discarding, cache_valid, engine_reply_pending;
static uint8_t request_cache[KG_BLE_REQUEST_MAX], reply_cache[KG_BLE_ACK_MAX];
static size_t request_size, reply_size, reply_symbol;
static uint32_t phase_at, quiet_at, last_send_at, reply_at, last_led_at;
static unsigned replays;

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static bool connected(void) { return get_transport() == TRANSPORT_BLUETOOTH && wireless_get_state() == WT_CONNECTED; }
static bool queue_idle(void) { return report_buffer_is_empty() && report_buffer_get_retry() == 0; }
static bool keys_idle(void) {
    for (uint8_t row = 0; row < MATRIX_ROWS; ++row) if (matrix_get_row(row)) return false;
    if (get_mods() || get_weak_mods() || get_oneshot_mods() || get_oneshot_locked_mods()) return false;
    if (keyboard_report->mods || keyboard_report->reserved) return false;
    for (uint8_t i = 0; i < KEYBOARD_REPORT_KEYS; ++i) if (keyboard_report->keys[i]) return false;
#ifdef NKRO_ENABLE
    if (nkro_report->mods) return false;
    for (uint8_t i = 0; i < NKRO_REPORT_BITS; ++i) if (nkro_report->bits[i]) return false;
#endif
    return host_last_consumer_usage() == 0 && host_last_system_usage() == 0;
}
static void initialize(uint8_t mask) {
    if (!initialized) {
        kg_ble_led_init(&decoder, mask); ble_rgb_arm(&rgb_guard, timer_read32(), mask); initialized = true;
    }
}
static void cancel(uint8_t mask) {
    /* This cannot retract an already acknowledged COMMIT or erase a durable
     * stage. It never calls delivered and never emits a release over typing. */
    const bool interrupted = phase != LINK_IDLE || decoder.collecting || decoder.ready || quarantine;
    if (phase != LINK_IDLE || engine_reply_pending) (void)keyglow_ota_cancel_pending();
    kg_ble_led_cancel(&decoder, mask); initialized = true;
    ble_rgb_arm(&rgb_guard, timer_read32(), mask);
    phase = LINK_IDLE; cache_valid = engine_reply_pending = false;
    quarantine = discarding = interrupted;
    if (interrupted) last_led_at = timer_read32();
    request_size = reply_size = reply_symbol = 0; replays = 0;
    memset(request_cache, 0, sizeof request_cache); memset(reply_cache, 0, sizeof reply_cache);
}
static bool safe(void) { return connected() && keys_idle() && !battery_is_critical_low(); }
static void settle(uint32_t now) { phase = LINK_SETTLING; phase_at = quiet_at = now; reply_symbol = 0; }

bool keyglow_ble_ota_busy(void) {
    return phase != LINK_IDLE || decoder.collecting || decoder.ready || quarantine || keyglow_ota_busy();
}
void keyglow_ble_ota_process_record(keyrecord_t *record) {
    if (record->event.pressed) cancel(host_keyboard_led_state().raw);
}
void keyglow_ble_ota_link_changed(void) { cancel(host_keyboard_led_state().raw); }
/* Handles disconnect/reconnect pairs consumed in one wireless housekeeping pass. */
void wireless_enter_connected_kb(uint8_t host_index) { (void)host_index; keyglow_ble_ota_link_changed(); }

bool keyglow_ble_ota_led_update(led_t state) {
    initialize(state.raw);
    if (!safe()) { cancel(state.raw); return !quarantine; }
    const uint32_t now = timer_read32();
    if (discarding) {
        if ((uint32_t)(now - last_led_at) < KG_BLE_LED_TIMEOUT_MS) { last_led_at = now; return false; }
        discarding = quarantine = false; kg_ble_led_cancel(&decoder, state.raw);
    }
    if (quarantine && (uint32_t)(now - last_led_at) >= KG_BLE_LED_TIMEOUT_MS && phase == LINK_IDLE) quarantine = false;
    const bool suppress_before = quarantine || phase != LINK_IDLE || decoder.collecting || decoder.ready || keyglow_ota_busy();
    last_led_at = now;
    if (!suppress_before) {
        ble_rgb_tick(&rgb_guard, now);
        /* Observe legacy frames too, without arming the real RGB decoder. */
        rgb_guard.armed = true; rgb_guard.armed_at = now;
        const bool was_rgb = rgb_guard.collecting;
        ble_rgb_command_t ignored;
        (void)ble_rgb_feed(&rgb_guard, now, state.raw, &ignored);
        if (was_rgb || rgb_guard.collecting) {
            kg_ble_led_cancel(&decoder, state.raw);
            return true;
        }
    }
    const kg_ble_event event = kg_ble_led_feed(&decoder, now, state.raw);
    if (event == KG_BLE_REJECTED && quarantine) { cancel(state.raw); return false; }
    if (decoder.collecting || decoder.ready) {
        quarantine = true; ble_rgb_arm(&rgb_guard, now, state.raw);
    }
    /* Even while sending, consume ACK_ACK symbols into the bounded mailbox.
     * All engine calls and receipt delivery occur in matrix_scan below. */
    return !(suppress_before || quarantine || phase != LINK_IDLE || keyglow_ota_busy());
}

static void consume_frame(uint32_t now) {
    uint8_t frame[KG_BLE_REQUEST_MAX]; size_t size = 0;
    if (!kg_ble_led_take(&decoder, frame, sizeof frame, &size)) return;
    if (frame[5] == KG_BLE_ACK_RECEIPT_OP) {
        if (phase == LINK_RECEIPT && cache_valid && kg_ble_ack_receipt_matches(frame, size, reply_cache, reply_size)) {
            const bool accepted = !engine_reply_pending || keyglow_ota_reply_delivered(le32(reply_cache + 6));
            if (!accepted) { cancel(host_keyboard_led_state().raw); return; }
            engine_reply_pending = false; phase = LINK_IDLE;
        }
        return; /* No receipt response and no receipt reaches the engine. */
    }
    if (cache_valid && (uint32_t)(now - reply_at) < 60000u && size == request_size && !memcmp(frame, request_cache, size)) {
        /* Retry a byte-identical transaction without re-executing a mutation.
         * Never restart a reply in flight; cap replays and keep original expiry. */
        if ((phase == LINK_RECEIPT || phase == LINK_IDLE) && replays < 2u) { ++replays; settle(now); }
        return;
    }
    if (phase != LINK_IDLE || keyglow_ota_busy()) return;
    if (!keyglow_ota_submit_frame(frame, size)) return;
    memcpy(request_cache, frame, size); request_size = size;
    cache_valid = engine_reply_pending = false; reply_size = 0; replays = 0;
    phase = LINK_ENGINE; phase_at = now;
}

void keyglow_ble_ota_task(void) {
    initialize(host_keyboard_led_state().raw);
    if (!safe()) { cancel(host_keyboard_led_state().raw); return; }
    const uint32_t now = timer_read32();
    if (discarding) {
        if ((uint32_t)(now - last_led_at) < KG_BLE_LED_TIMEOUT_MS) return;
        discarding = quarantine = false; kg_ble_led_cancel(&decoder, host_keyboard_led_state().raw);
    }
    (void)kg_ble_led_tick(&decoder, now);
    if (quarantine && phase == LINK_IDLE && !decoder.collecting && !decoder.ready && (uint32_t)(now - last_led_at) >= KG_BLE_LED_TIMEOUT_MS) quarantine = false;
    if (cache_valid && (uint32_t)(now - reply_at) >= 60000u) {
        if (phase != LINK_IDLE) { cancel(host_keyboard_led_state().raw); return; }
        cache_valid = false;
    }
    if (decoder.ready) consume_frame(now);
    if (phase == LINK_ENGINE) {
        if ((uint32_t)(now - phase_at) >= 60000u) { cancel(host_keyboard_led_state().raw); return; }
        uint8_t legacy[120]; size_t length = 0;
        if (!keyglow_ota_peek_reply(legacy, sizeof legacy, &length)) return;
        if (length != sizeof legacy || le32(legacy + 8) != le32(request_cache + 8) || (legacy[5] & 0x7fu) != request_cache[5] ||
            !kg_ble_ack_from_legacy(legacy, length, request_cache[5] == 3u || request_cache[5] == 8u, reply_cache, sizeof reply_cache, &reply_size)) {
            cancel(host_keyboard_led_state().raw); return;
        }
        cache_valid = engine_reply_pending = true; reply_at = now; settle(now);
    }
    if (phase == LINK_SETTLING) {
        if ((uint32_t)(now - phase_at) >= 5000u) { cancel(host_keyboard_led_state().raw); return; }
        if (!queue_idle()) { quiet_at = now; return; }
        if ((uint32_t)(now - quiet_at) < 600u) return;
        phase = LINK_SENDING; last_send_at = now - KG_BLE_REPLY_DEFAULT_MS;
    }
    if (phase != LINK_SENDING) return;
    if (!queue_idle()) { cancel(host_keyboard_led_state().raw); return; }
    if ((uint32_t)(now - last_send_at) < KG_BLE_REPLY_DEFAULT_MS) return;
    uint8_t report[8];
    if (!kg_ble_ack_report(reply_cache, reply_size, reply_symbol, report)) { cancel(host_keyboard_led_state().raw); return; }
    /* Existing LKBT51 keyboard-report path, eight bytes. Data is confined to
     * reserved; all modifiers and keycodes are zero. No report queue/retry. */
    lkbt51_send_keyboard(report);
    last_send_at = now;
    if (reply_symbol++ == reply_size * 2u) { phase = LINK_RECEIPT; phase_at = now; }
}
