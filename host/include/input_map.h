#ifndef TRIAD_INPUT_MAP_H
#define TRIAD_INPUT_MAP_H

#include <SDL.h>

#include "touch.h"

// Maps SDL mouse/keyboard events to touch_event_t. Returns true if `ev` was
// filled and should be pushed to the touch queue.
//
// Keyboard equivalents (for laptop use without a touchscreen):
//   ←/→     → SWIPE_L / SWIPE_R at center of spectrum region
//   ↑/↓     → tap freq up / freq down buttons
//   M       → tap mute
//   R       → tap record
//   1/2/3   → tap layout button repeatedly to reach that layout
//   Space   → tap at mouse cursor
//   L       → long press at mouse cursor
bool input_map_translate(const SDL_Event *e,
                         int mouse_x, int mouse_y,
                         touch_event_t *ev);

#endif
