// Drives ui_logic.c through scripted touch sequences using a tiny mock HAL.
// hal_now_us / hal_touch_poll / hal_spi_send / hal_log / hal_sleep_ms are
// replaced with controllable stand-ins.

#include <string.h>

#include "hal_pico.h"
#include "regions.h"
#include "screen_config.h"
#include "test_helpers.h"
#include "touch.h"
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

#define STATUS_BTN_W 32
#define STATUS_BTN_GAP 4
static uint16_t btn_x0(uint8_t id) {
    return (uint16_t)(SCREEN_W - (uint16_t)(id + 1) * (STATUS_BTN_W + STATUS_BTN_GAP));
}
static uint16_t btn_cx(uint8_t id) { return (uint16_t)(btn_x0(id) + STATUS_BTN_W / 2); }
static uint16_t btn_cy(void)       { return 16; }

static void push_tap(uint8_t btn) {
    touch_event_t ev = { .x = btn_cx(btn), .y = btn_cy(), .kind = TOUCH_TAP };
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

T_CASE(layout_cycles_through_all) {
    mock_reset();
    ui_logic_t L; ui_logic_init(&L);
    uint8_t l0 = L.curr.layout;
    for (unsigned i = 0; i < LAYOUT_COUNT; i++) { push_tap(UI_BTN_LAYOUT); ui_logic_tick(&L); }
    T_EXPECT_EQ(L.curr.layout, l0);
    // One short of a full cycle must land somewhere else.
    push_tap(UI_BTN_LAYOUT); ui_logic_tick(&L);
    T_EXPECT(L.curr.layout != l0);
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

int main(void) {
    T_RUN(freq_up_5_taps);
    T_RUN(mute_toggles);
    T_RUN(layout_cycles_through_all);
    T_RUN(volume_clamps_at_0_and_100);
    T_RUN(touch_down_then_drag_off_button_cancels);
    T_RUN(spi_emits_full_state_first);
    T_FINISH();
}
