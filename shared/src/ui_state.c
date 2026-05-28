#include "ui_state.h"

#include <string.h>

uint8_t ui_layout_for_demod(uint8_t demod) {
    switch (demod) {
    case DEMOD_GOES: return (uint8_t)LAYOUT_GOES_FULL;
    case DEMOD_ADSB: return (uint8_t)LAYOUT_ADSB_FULL;
    default:         return (uint8_t)LAYOUT_SPECTRUM_ONLY;  // FM and AM
    }
}

void ui_state_default(ui_state_t *st) {
    memset(st, 0, sizeof(*st));
    st->version       = (uint8_t)UI_STATE_VERSION;
    st->demod         = (uint8_t)DEMOD_FM;
    st->layout        = ui_layout_for_demod((uint8_t)DEMOD_FM);
    st->volume        = 50;
    st->freq_hz       = 100000000u;  // 100 MHz
    st->span_hz_log2  = 17;          // 128 kHz span
    st->squelch       = 20;
    st->flags         = 0;
    st->touch_x       = 0;
    st->touch_y       = 0;
    st->active_button = UI_BTN_NONE;
    st->brightness    = 80;
    st->adsb_range_mi = 75;
    st->rds_text[0]   = '\0';
}
