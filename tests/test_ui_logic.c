// Drives ui_logic.c through scripted touch sequences using a tiny mock HAL.
// hal_now_us / hal_touch_poll / hal_spi_send / hal_log / hal_sleep_ms are
// replaced with controllable stand-ins.

#include <string.h>

#include "hal_pico.h"
#include "regions.h"
#include "screen_config.h"
#include "test_helpers.h"
#include "touch.h"
#include "ui_controls.h"
#include "ui_logic.h"
#include "ui_state.h"

static uint64_t g_mock_now_us = 0;
static touch_event_queue_t g_mock_q;
static uint8_t g_mock_spi_buf[16384];
static size_t  g_mock_spi_len;

uint64_t hal_now_us(void) { return g_mock_now_us; }
void hal_log(const char *fmt, ...) { (void)fmt; }
bool hal_touch_poll(touch_event_t *out) { return touch_queue_pop(&g_mock_q, out); }
void hal_spi_send(const uint8_t *buf, size_t len) {
    if (g_mock_spi_len + len > sizeof(g_mock_spi_buf)) return;
    memcpy(g_mock_spi_buf + g_mock_spi_len, buf, len);
    g_mock_spi_len += len;
}
void hal_sleep_ms(uint32_t ms) { (void)ms; }

static void mock_reset(void) {
    g_mock_now_us = 0;
    g_mock_spi_len = 0;
    touch_queue_init(&g_mock_q);
}

static uint16_t btn_cx(uint8_t id) { return ui_button_cx(id); }
static uint16_t btn_cy(void)       { return ui_button_cy(); }

static void push_tap(uint8_t btn) {
    touch_event_t ev = { .x = btn_cx(btn), .y = btn_cy(), .kind = TOUCH_TAP };
    touch_queue_push(&g_mock_q, &ev);
}

// Push an arbitrary touch kind centered on a button (coords ignored by the
// span-swipe handlers, used for DOWN/UP/LONG on a specific button otherwise).
static void push_event(uint8_t btn, uint8_t kind) {
    touch_event_t ev = { .x = btn_cx(btn), .y = btn_cy(), .kind = kind };
    touch_queue_push(&g_mock_q, &ev);
}

T_CASE(freq_up_5_taps) {
    mock_reset();
    ui_logic_t L;
    ui_logic_init(&L);

    uint32_t before = L.curr.freq_hz;
    for (int i = 0; i < 5; i++) {
        push_tap(UI_BTN_FREQ_UP);
        ui_logic_tick(&L);
        g_mock_now_us += 16000;
    }
    T_EXPECT_EQ((long long)L.curr.freq_hz - (long long)before, 5LL * 100000LL);
    return 0;
}

T_CASE(mute_toggles) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    T_EXPECT_EQ((L.curr.flags & UI_FLAG_MUTE) != 0, 0);
    push_tap(UI_BTN_MUTE); ui_logic_tick(&L);
    T_EXPECT((L.curr.flags & UI_FLAG_MUTE) != 0);
    push_tap(UI_BTN_MUTE); ui_logic_tick(&L);
    T_EXPECT_EQ((L.curr.flags & UI_FLAG_MUTE) != 0, 0);
    return 0;
}

// The page is no longer an independent control: cycling the mode drives the
// layout in lockstep so demod and page can never mismatch.
T_CASE(layout_follows_demod) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_FM);
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_SPECTRUM_ONLY);

    push_tap(UI_BTN_MODE); ui_logic_tick(&L);   // AM still shares the spectrum page
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_AM);
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_SPECTRUM_ONLY);

    push_tap(UI_BTN_MODE); ui_logic_tick(&L);   // GOES → full-screen image page
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_GOES);
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_GOES_FULL);

    push_tap(UI_BTN_MODE); ui_logic_tick(&L);   // ADS-B → full-screen map page
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_ADSB);
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_ADSB_FULL);
    return 0;
}

// Frequency and span are inert on the image pages — only the FM/AM spectrum
// page tunes.
T_CASE(tuning_gated_to_spectrum_page) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    push_tap(UI_BTN_MODE); push_tap(UI_BTN_MODE); ui_logic_tick(&L);  // FM → AM → GOES
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_GOES_FULL);

    uint32_t f0 = L.curr.freq_hz;
    uint16_t s0 = L.curr.span_hz_log2;
    push_tap(UI_BTN_FREQ_UP); ui_logic_tick(&L);
    push_event(0, TOUCH_SWIPE_L); ui_logic_tick(&L);
    T_EXPECT_EQ((long long)L.curr.freq_hz, (long long)f0);
    T_EXPECT_EQ(L.curr.span_hz_log2, s0);
    return 0;
}

T_CASE(image_pages_only_expose_mode_button) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    push_tap(UI_BTN_MODE); push_tap(UI_BTN_MODE); ui_logic_tick(&L);  // FM -> AM -> GOES
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_GOES_FULL);

    uint8_t vol0 = L.curr.volume;
    push_tap(UI_BTN_VOL_UP); ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.volume, vol0);

    push_tap(UI_BTN_MODE); ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_ADSB);
    T_EXPECT_EQ(L.curr.layout, (uint8_t)LAYOUT_ADSB_FULL);
    return 0;
}

T_CASE(volume_clamps_at_0_and_100) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    for (int i = 0; i < 30; i++) { push_tap(UI_BTN_VOL_UP); ui_logic_tick(&L); }
    T_EXPECT_EQ(L.curr.volume, 100);
    for (int i = 0; i < 30; i++) { push_tap(UI_BTN_VOL_DN); ui_logic_tick(&L); }
    T_EXPECT_EQ(L.curr.volume, 0);
    return 0;
}

T_CASE(touch_down_then_drag_off_button_cancels) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    touch_event_t down = { .x = btn_cx(UI_BTN_FREQ_UP), .y = btn_cy(), .kind = TOUCH_DOWN };
    touch_event_t move = { .x = 100,                    .y = 300,     .kind = TOUCH_MOVE };
    touch_event_t up   = { .x = 100,                    .y = 300,     .kind = TOUCH_UP   };
    touch_queue_push(&g_mock_q, &down);
    touch_queue_push(&g_mock_q, &move);
    touch_queue_push(&g_mock_q, &up);
    uint32_t before = L.curr.freq_hz;
    ui_logic_tick(&L);
    T_EXPECT_EQ((long long)L.curr.freq_hz, (long long)before);
    return 0;
}

T_CASE(spi_emits_full_state_first) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    ui_logic_tick(&L);
    T_EXPECT(g_mock_spi_len > 0);
    // First byte should be the magic.
    T_EXPECT_EQ(g_mock_spi_buf[0], 0xA5);
    // Second byte is opcode — should be FULL_STATE on first tick.
    T_EXPECT_EQ(g_mock_spi_buf[1], 0x01);
    return 0;
}

T_CASE(freq_down_decrements_and_clamps_at_zero) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);

    uint32_t before = L.curr.freq_hz;
    push_tap(UI_BTN_FREQ_DN); ui_logic_tick(&L);
    T_EXPECT_EQ((long long)before - (long long)L.curr.freq_hz, 100000LL);

    // Below one big step it must clamp rather than underflow (wrap to ~4 GHz).
    L.curr.freq_hz = 50000;
    push_tap(UI_BTN_FREQ_DN); ui_logic_tick(&L);
    T_EXPECT_EQ((long long)L.curr.freq_hz, 50000LL);
    return 0;
}

T_CASE(mode_cycles_demod) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_FM);
    push_tap(UI_BTN_MODE); ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_AM);
    // A full cycle returns to the start.
    for (unsigned i = 1; i < DEMOD_COUNT; i++) { push_tap(UI_BTN_MODE); ui_logic_tick(&L); }
    T_EXPECT_EQ(L.curr.demod, (uint8_t)DEMOD_FM);
    return 0;
}

// Press-and-release inside the same button fires the action (the firing
// counterpart to touch_down_then_drag_off_button_cancels).
T_CASE(down_then_up_inside_button_fires) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    uint32_t before = L.curr.freq_hz;
    push_event(UI_BTN_FREQ_UP, TOUCH_DOWN);
    push_event(UI_BTN_FREQ_UP, TOUCH_UP);
    ui_logic_tick(&L);
    T_EXPECT_EQ((long long)L.curr.freq_hz - (long long)before, 100000LL);
    // Touch-active flag and button highlight are cleared after release.
    T_EXPECT_EQ((L.curr.flags & UI_FLAG_TOUCH_ACTIVE) != 0, 0);
    T_EXPECT_EQ(L.curr.active_button, UI_BTN_NONE);
    return 0;
}

T_CASE(swipes_change_span_with_clamps) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    uint16_t span0 = L.curr.span_hz_log2;    // default 17

    push_event(0, TOUCH_SWIPE_L); ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.span_hz_log2, span0 + 1);
    push_event(0, TOUCH_SWIPE_R); ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.span_hz_log2, span0);

    // Clamp high at 24.
    for (int i = 0; i < 20; i++) { push_event(0, TOUCH_SWIPE_L); }
    ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.span_hz_log2, 24);
    // Clamp low at 8.
    for (int i = 0; i < 30; i++) { push_event(0, TOUCH_SWIPE_R); }
    ui_logic_tick(&L);
    T_EXPECT_EQ(L.curr.span_hz_log2, 8);
    return 0;
}

// Taps below the status bar hit no button and change nothing.
T_CASE(tap_below_status_bar_ignored) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    uint32_t before = L.curr.freq_hz;
    touch_event_t ev = { .x = btn_cx(UI_BTN_FREQ_UP), .y = 300, .kind = TOUCH_TAP };
    touch_queue_push(&g_mock_q, &ev);
    ui_logic_tick(&L);
    T_EXPECT_EQ((long long)L.curr.freq_hz, (long long)before);
    return 0;
}

// State sync cadence: full snapshot on the first tick, partials in between,
// and another full every FULL_SYNC_EVERY_FRAMES (16) ticks.
T_CASE(sync_cadence_full_then_partials) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);

    for (int tick = 0; tick < 17; tick++) {
        g_mock_now_us += 16000;
        // Change state each tick so partials carry a non-empty diff.
        ui_logic_inject_touch(&L, btn_cx(UI_BTN_FREQ_UP), btn_cy(), TOUCH_TAP);
        g_mock_spi_len = 0;              // isolate this tick's emission
        ui_logic_tick(&L);              // queue empty → only emit_state runs

        T_EXPECT(g_mock_spi_len >= 2);
        T_EXPECT_EQ(g_mock_spi_buf[0], 0xA5);
        uint8_t op = g_mock_spi_buf[1];
        if (tick == 0 || tick == 16) T_EXPECT_EQ(op, 0x01);   // OP_FULL_STATE
        else                         T_EXPECT_EQ(op, 0x02);   // OP_PARTIAL_STATE
    }
    return 0;
}

int main(void) {
    T_RUN(freq_up_5_taps);
    T_RUN(mute_toggles);
    T_RUN(layout_follows_demod);
    T_RUN(tuning_gated_to_spectrum_page);
    T_RUN(image_pages_only_expose_mode_button);
    T_RUN(volume_clamps_at_0_and_100);
    T_RUN(touch_down_then_drag_off_button_cancels);
    T_RUN(spi_emits_full_state_first);
    T_RUN(freq_down_decrements_and_clamps_at_zero);
    T_RUN(mode_cycles_demod);
    T_RUN(down_then_up_inside_button_fires);
    T_RUN(swipes_change_span_with_clamps);
    T_RUN(tap_below_status_bar_ignored);
    T_RUN(sync_cadence_full_then_partials);
    T_FINISH();
}
