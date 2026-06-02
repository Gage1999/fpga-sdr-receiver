// Goodix capacitive touch controller driver — STUB.
//
// Bring-up (2026-06-01) pinned down the part: Goodix GT911, 7-bit I²C
// address 0x5D, on i2c0 (SDA=GP4, SCL=GP5). Product-ID register 0x8140
// reads ASCII "911". The INT pin level when RST is released selects the
// address (low/floating -> 0x5D, high -> 0x14). The bring-up scanner lives
// in pico2w/src/i2c_touch_probe/.
//
// TODO: implement init + raw-point polling (GT911 reports up to 5 points;
// touch status at 0x814E, point data from 0x8150). Gesture detection
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
