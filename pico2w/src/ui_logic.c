#include "ui_logic.h"

#include <string.h>

#include "hal_pico.h"
#include "screen_config.h"
#include "ui_controls.h"
#include "ui_state.h"
#include "wire_protocol.h"

// ──────────────────────────────────────────────────────────────────────────────
// Constants that govern UI feel. All chosen to be FPGA-translatable when the
// Pico is replaced by an FPGA-internal soft state machine someday (it won't
// be, but the discipline is cheap).
// ──────────────────────────────────────────────────────────────────────────────

#define FULL_SYNC_EVERY_FRAMES 16u
#define LONG_PRESS_US 600000ull  // 600 ms

#define FREQ_STEP_BIG 100000u    // 100 kHz
#define FREQ_STEP_SMALL 10000u   // 10 kHz
#define VOL_STEP 5u

// Returns UI_BTN_NONE if outside any button.
static uint8_t hit_button(const ui_logic_t *L, uint16_t x, uint16_t y) {
    uint8_t btn = UI_BTN_NONE;
    if (ui_button_hit(x, y, L->curr.layout, &btn)) return btn;
    return UI_BTN_NONE;
}

void ui_logic_init(ui_logic_t *L) {
    memset(L, 0, sizeof(*L));
    ui_state_default(&L->curr);
    L->prev_sent = L->curr;
    L->last_sync_us = 0;
    L->frames_since_full = 0;
    L->touch_is_down = 0;
}

// Emits a frame describing the touch event to the FPGA.
static uint32_t emit_touch(uint16_t x, uint16_t y, uint8_t kind) {
    touch_event_t ev = { .x = x, .y = y, .kind = kind, .reserved = 0 };
    uint8_t frame[WIRE_OVERHEAD + 5];
    size_t n = wire_pack_touch(frame, sizeof(frame), &ev);
    if (n > 0) hal_spi_send(frame, n);
    return n > 0 ? 1u : 0u;
}

static uint32_t emit_state(ui_logic_t *L) {
    uint8_t frame[WIRE_MAX_FRAME];
    L->frames_since_full++;
    if (L->frames_since_full >= FULL_SYNC_EVERY_FRAMES || L->last_sync_us == 0) {
        size_t n = wire_pack_full(frame, sizeof(frame), &L->curr);
        if (n > 0) {
            hal_spi_send(frame, n);
            L->prev_sent = L->curr;
            L->frames_since_full = 0;
            return 1;
        }
        return 0;
    }
    size_t n = wire_pack_partial(frame, sizeof(frame), &L->prev_sent, &L->curr);
    if (n > 0) {
        hal_spi_send(frame, n);
        L->prev_sent = L->curr;
        return 1;
    }
    return 0;
}

// ──────────────────────────────────────────────────────────────────────────────
// Action handlers. Pure mutation of L->curr. Wire emission deferred to end.
// ──────────────────────────────────────────────────────────────────────────────

// Switches the active mode and snaps the page to match — they move together
// because only one mode can run at a time (single RX LO).
static void set_demod(ui_logic_t *L, uint8_t demod) {
    L->curr.demod = demod;
    L->curr.layout = ui_layout_for_demod(demod);
}

// Frequency/span controls only make sense on the FM/AM spectrum page; the
// image modes (GOES, ADS-B) ignore them.
static int on_spectrum_page(const ui_logic_t *L) {
    return L->curr.layout == LAYOUT_SPECTRUM_ONLY;
}

static void action_button_press(ui_logic_t *L, uint8_t btn) {
    switch (btn) {
    case UI_BTN_FREQ_UP:
        if (on_spectrum_page(L)) L->curr.freq_hz += FREQ_STEP_BIG;
        break;
    case UI_BTN_FREQ_DN:
        if (on_spectrum_page(L) && L->curr.freq_hz >= FREQ_STEP_BIG) L->curr.freq_hz -= FREQ_STEP_BIG;
        break;
    case UI_BTN_VOL_UP:
        L->curr.volume = (uint8_t)((L->curr.volume + VOL_STEP > 100) ? 100 : L->curr.volume + VOL_STEP);
        break;
    case UI_BTN_VOL_DN:
        L->curr.volume = (uint8_t)((L->curr.volume < VOL_STEP) ? 0 : L->curr.volume - VOL_STEP);
        break;
    case UI_BTN_MODE:
        set_demod(L, (uint8_t)((L->curr.demod + 1) % DEMOD_COUNT));
        break;
    case UI_BTN_MUTE:
        L->curr.flags ^= UI_FLAG_MUTE;
        break;
    default: break;
    }
}

static void handle_touch(ui_logic_t *L, const touch_event_t *ev) {
    switch (ev->kind) {
    case TOUCH_DOWN: {
        L->touch_is_down = 1;
        L->touch_down_us = hal_now_us();
        L->touch_down_x = ev->x;
        L->touch_down_y = ev->y;
        L->curr.touch_x = ev->x;
        L->curr.touch_y = ev->y;
        L->curr.flags |= UI_FLAG_TOUCH_ACTIVE;
        uint8_t btn = hit_button(L, ev->x, ev->y);
        L->curr.active_button = btn;
        break;
    }
    case TOUCH_MOVE: {
        L->curr.touch_x = ev->x;
        L->curr.touch_y = ev->y;
        // Cancel button highlight if drag leaves it.
        if (L->curr.active_button != UI_BTN_NONE) {
            uint8_t btn = hit_button(L, ev->x, ev->y);
            if (btn != L->curr.active_button) L->curr.active_button = UI_BTN_NONE;
        }
        break;
    }
    case TOUCH_UP: {
        L->touch_is_down = 0;
        // If we released inside the originally-pressed button, fire it.
        uint8_t btn = hit_button(L, ev->x, ev->y);
        if (btn != UI_BTN_NONE && btn == L->curr.active_button) {
            action_button_press(L, btn);
        }
        L->curr.active_button = UI_BTN_NONE;
        L->curr.flags &= (uint8_t)~UI_FLAG_TOUCH_ACTIVE;
        break;
    }
    case TOUCH_TAP: {
        uint8_t btn = hit_button(L, ev->x, ev->y);
        if (btn != UI_BTN_NONE) action_button_press(L, btn);
        break;
    }
    case TOUCH_LONG: {
        break;
    }
    case TOUCH_SWIPE_L: {
        if (on_spectrum_page(L) && L->curr.span_hz_log2 < 24) L->curr.span_hz_log2++;
        break;
    }
    case TOUCH_SWIPE_R: {
        if (on_spectrum_page(L) && L->curr.span_hz_log2 > 8) L->curr.span_hz_log2--;
        break;
    }
    default: break;
    }
}

void ui_logic_inject_touch(ui_logic_t *L, uint16_t x, uint16_t y, uint8_t kind) {
    touch_event_t ev = { .x = x, .y = y, .kind = kind, .reserved = 0 };
    handle_touch(L, &ev);
}

uint32_t ui_logic_tick(ui_logic_t *L) {
    uint32_t sent = 0;

    touch_event_t ev;
    while (hal_touch_poll(&ev)) {
        handle_touch(L, &ev);
        sent += emit_touch(ev.x, ev.y, ev.kind);
    }

    // Auto-detect long-press by held-down duration.
    if (L->touch_is_down) {
        uint64_t now = hal_now_us();
        if (now - L->touch_down_us > LONG_PRESS_US) {
            touch_event_t lp = {
                .x = L->touch_down_x, .y = L->touch_down_y,
                .kind = TOUCH_LONG, .reserved = 0,
            };
            handle_touch(L, &lp);
            sent += emit_touch(lp.x, lp.y, lp.kind);
            L->touch_is_down = 0;  // consume; user must release+press for another
        }
    }

    // Emit state diff (or full sync every N frames).
    sent += emit_state(L);
    L->last_sync_us = hal_now_us();
    return sent;
}
