#ifndef TRIAD_PIXEL_SHADER_H
#define TRIAD_PIXEL_SHADER_H

#include <stdint.h>

#include "aux_roms.h"
#include "ui_state.h"

// Pure function. Given UI state, FB pixel under this position, and EBR ROMs,
// return the final RGB565 for (x, y).
//
// On hardware: combinational + ROM lookups on the pixel clock. The C is
// the executable spec — the SV implementation must produce identical
// output for identical inputs.
uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const ui_state_t *ui,
                      const aux_roms_t *roms);

#endif
