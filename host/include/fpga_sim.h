#ifndef TRIAD_FPGA_SIM_H
#define TRIAD_FPGA_SIM_H

#include "aux_roms.h"
#include "fb_host.h"
#include "screen_config.h"
#include "ui_state.h"

typedef struct {
    struct fb   fb;
    ui_state_t  shadow;       // back buffer the wire writes into
    ui_state_t  shadow_front; // front buffer the shader reads from
    aux_roms_t  roms;
    uint8_t     last_layout;  // layout composited last frame; mode-change detect
    uint16_t    goes_next_row;
} fpga_sim_t;

void fpga_sim_init(fpga_sim_t *s);

// Drain the in-process SPI link, apply UI state updates. Composite any
// pending FB-write ops from synth_data. Re-render the full screen via the
// pixel shader into `pixels_out` (SCREEN_W * SCREEN_H halfwords).
void fpga_sim_tick(fpga_sim_t *s, uint16_t *pixels_out);

#endif
