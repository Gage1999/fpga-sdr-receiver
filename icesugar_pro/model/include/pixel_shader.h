#ifndef TRIAD_PIXEL_SHADER_H
#define TRIAD_PIXEL_SHADER_H

#include <stdint.h>

#include "aux_roms.h"
#include "ui_state.h"

#define SHADER_BAND_TEXT_CHARS 20u

// State the per-pixel shader reads. Populated once per frame by
typedef struct {
    uint8_t  layout;
    uint8_t  demod;
    uint8_t  flags;
    uint8_t  active_button;
    uint16_t touch_x;
    uint16_t touch_y;

    // BRAM read port stand-in: SV wires this to spectrum_bin_ram's port B.
    const uint16_t *spectrum_bins;

    // Precomputed text. Sized to the worst-case glyph count each line draws.
    char     freq_text[12];      // "NNN.NN MHz "
    char     band_text[SHADER_BAND_TEXT_CHARS]; // "LLL.lll-RRR.rrrMHz"
    char     demod_label[4];     // "FM  ", "AM  ", "GOES", "ADSB"
    char     rds_line[24];       // left-aligned FM RDS/radio text, if available
    char     mode_btn_label[2];  // "FM", "AM", "GO", "AD"

    // Displayed FFT window. The DSP path changes RF span before the 256-bin FFT,
    // so the shader normally consumes the full display-order row.
    uint8_t  spectrum_start_bin;
    uint16_t spectrum_visible_bins;

    // label_origin outputs for each text button in the status bar.
    int16_t  mode_btn_text_x;
    int16_t  mode_btn_text_y;
    int16_t  plus_text_x;
    int16_t  plus_text_y;
    int16_t  minus_text_x;
    int16_t  minus_text_y;

    // ui->volume * status-bar-fill-width / 100, clamped to that width.
    uint16_t volume_fill_px;

    // SPR_BTN_MUTE_ON if UI_FLAG_MUTE else SPR_BTN_MUTE.
    uint8_t  mute_sprite_id;
} shader_state_t;

// Snapshot ui_state into shader_state at V-sync. Pure: no globals, no malloc.
void pixel_shader_prepare(const ui_state_t *ui, const aux_roms_t *roms,
                          shader_state_t *out);

// Pure function. Given the prepared shader state, FB pixel under this
uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const shader_state_t *state,
                      const aux_roms_t *roms);

#endif
