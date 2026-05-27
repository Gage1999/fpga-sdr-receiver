// Goodix capacitive touch controller driver — STUB.
//
// On hardware bring-up: pin down the exact part (GT911 family likely) and
// I²C address, then implement init + raw-point polling. Gesture detection
// (tap/long/swipe) stays in ui_logic.c so the harness exercises the same
// gesture code paths.

#ifdef TRIAD_FIRMWARE
#include "hardware/i2c.h"
#include "touch.h"

void touch_goodix_init(void) {
    // TODO
}

bool touch_goodix_poll(touch_event_t *out) {
    (void)out;
    return false;
}
#endif
