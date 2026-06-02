#ifndef TRIAD_UI_STATE_H
#define TRIAD_UI_STATE_H

#include <stdint.h>

#ifndef UI_STATE_VERSION
#define UI_STATE_VERSION 3u
#endif

typedef enum : uint8_t {
    DEMOD_FM   = 0,
    DEMOD_AM   = 1,
    DEMOD_GOES = 2,
    DEMOD_ADSB = 3,
} demod_mode_t;

#define DEMOD_COUNT 4u

typedef enum : uint8_t {
    LAYOUT_SPECTRUM_ONLY = 0,
    LAYOUT_GOES_FULL     = 1,
    LAYOUT_ADSB_FULL     = 2,
} layout_t;

#define LAYOUT_COUNT 3u

#define UI_FLAG_MUTE         (1u << 0)
#define UI_FLAG_RECORD       (1u << 1)
#define UI_FLAG_TOUCH_ACTIVE (1u << 2)

#define UI_BTN_NONE      0xFFu
#define UI_BTN_FREQ_UP   0u
#define UI_BTN_FREQ_DN   1u
#define UI_BTN_VOL_UP    2u
#define UI_BTN_VOL_DN    3u
#define UI_BTN_MODE      4u
#define UI_BTN_MUTE      5u
#define UI_BTN_ZOOM_IN   6u
#define UI_BTN_ZOOM_OUT  7u
#define UI_BTN_COUNT     8u
#define UI_BTN_MAIN_COUNT UI_BTN_COUNT

#define UI_SPAN_LOG2_MIN 13u
#define UI_SPAN_LOG2_MAX 18u

#define UI_SPECTRUM_BINS 256

typedef struct __attribute__((packed)) {
    uint8_t  version;
    uint8_t  layout;
    uint8_t  demod;
    uint8_t  volume;
    uint32_t freq_hz;
    uint16_t span_hz_log2;
    uint8_t  squelch;
    uint8_t  flags;
    uint16_t touch_x;
    uint16_t touch_y;
    uint8_t  active_button;
    uint8_t  brightness;
    uint8_t  adsb_range_mi;
    uint8_t  reserved[1];
    char     rds_text[32];
    uint16_t spectrum_bins[UI_SPECTRUM_BINS];
} ui_state_t;

_Static_assert(sizeof(ui_state_t) <= 1024, "ui_state_t exceeds 1KB shadow RAM budget");

void ui_state_default(ui_state_t *st);

// Derives the page/layout from the active demod mode. Only one mode runs at a
// time (single RX LO), so the page always matches the mode: FM and AM share the
// spectrum+waterfall page; GOES and ADS-B each own a full-screen page.
uint8_t ui_layout_for_demod(uint8_t demod);

#endif
