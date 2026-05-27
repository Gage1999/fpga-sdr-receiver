#ifndef TRIAD_UI_LOGIC_H
#define TRIAD_UI_LOGIC_H

#include <stdbool.h>
#include <stdint.h>

#include "ui_state.h"

// One self-contained instance of the Pico-side UI logic. Same struct used
// on host (for the harness) and on Pico (for the real firmware).
typedef struct {
    ui_state_t curr;
    ui_state_t prev_sent;   // last state the FPGA has seen (best-effort)
    uint64_t   last_sync_us;
    uint32_t   frames_since_full;
    uint64_t   touch_down_us;
    uint16_t   touch_down_x, touch_down_y;
    uint8_t    touch_is_down;
    uint8_t    reserved;
} ui_logic_t;

void ui_logic_init(ui_logic_t *L);

// One iteration. Polls touch via HAL, mutates curr, emits wire frames via HAL.
// Returns the number of wire frames sent this tick.
uint32_t ui_logic_tick(ui_logic_t *L);

// Test seam: inject a touch event directly (skips hal_touch_poll).
void ui_logic_inject_touch(ui_logic_t *L, uint16_t x, uint16_t y, uint8_t kind);

#endif
