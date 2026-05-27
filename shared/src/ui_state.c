#include "ui_state.h"

#include <string.h>

void ui_state_default(ui_state_t *st) {
    memset(st, 0, sizeof(*st));
    st->version       = (uint8_t)UI_STATE_VERSION;
    st->layout        = (uint8_t)LAYOUT_SPLIT;
    st->demod         = (uint8_t)DEMOD_FM;
    st->volume        = 50;
    st->freq_hz       = 100000000u;  // 100 MHz
    st->span_hz_log2  = 17;          // 128 kHz span
    st->squelch       = 20;
    st->flags         = 0;
    st->touch_x       = 0;
    st->touch_y       = 0;
    st->active_button = UI_BTN_NONE;
    st->brightness    = 80;
}
