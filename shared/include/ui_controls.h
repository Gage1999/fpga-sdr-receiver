#ifndef TRIAD_UI_CONTROLS_H
#define TRIAD_UI_CONTROLS_H

#include <stdint.h>

#include "screen_config.h"
#include "ui_state.h"

#define UI_STATUS_BTN_W      48u
#define UI_STATUS_BTN_GAP     6u
#define UI_STATUS_BTN_TOP     8u
#define UI_STATUS_BTN_BOTTOM (UI_STATUS_BTN_TOP + UI_STATUS_BTN_W)

static inline uint8_t ui_layout_is_image(uint8_t layout) {
    return layout == (uint8_t)LAYOUT_GOES_FULL || layout == (uint8_t)LAYOUT_ADSB_FULL;
}

static inline uint8_t ui_button_visible(uint8_t layout, uint8_t btn) {
    if (ui_layout_is_image(layout)) return btn == UI_BTN_MODE;
    return btn < UI_BTN_COUNT;
}

static inline uint8_t ui_button_slot(uint8_t btn) {
    switch (btn) {
    case UI_BTN_MODE:    return 0u;
    case UI_BTN_MUTE:    return 1u;
    case UI_BTN_VOL_DN:  return 2u;
    case UI_BTN_VOL_UP:  return 3u;
    case UI_BTN_FREQ_DN: return 4u;
    case UI_BTN_FREQ_UP: return 5u;
    default:             return 0xffu;
    }
}

static inline uint16_t ui_button_x0(uint8_t btn) {
    uint8_t slot = ui_button_slot(btn);
    if (slot == 0xffu) return SCREEN_W;
    return (uint16_t)(SCREEN_W - (uint16_t)(slot + 1u) * (UI_STATUS_BTN_W + UI_STATUS_BTN_GAP));
}

static inline uint16_t ui_button_y0(void) {
    return UI_STATUS_BTN_TOP;
}

static inline uint16_t ui_button_cx(uint8_t btn) {
    return (uint16_t)(ui_button_x0(btn) + UI_STATUS_BTN_W / 2u);
}

static inline uint16_t ui_button_cy(void) {
    return (uint16_t)(UI_STATUS_BTN_TOP + UI_STATUS_BTN_W / 2u);
}

static inline uint8_t ui_button_hit(uint16_t x, uint16_t y, uint8_t layout, uint8_t *out_btn) {
    if (y < UI_STATUS_BTN_TOP || y >= UI_STATUS_BTN_BOTTOM) return 0u;
    for (uint8_t i = 0; i < UI_BTN_COUNT; i++) {
        if (!ui_button_visible(layout, i)) continue;
        uint16_t x0 = ui_button_x0(i);
        if (x >= x0 && x < x0 + UI_STATUS_BTN_W) {
            *out_btn = i;
            return 1u;
        }
    }
    return 0u;
}

#endif
