#ifndef TRIAD_FB_COMPOSITOR_H
#define TRIAD_FB_COMPOSITOR_H

#include <stdint.h>

#include "aux_roms.h"
#include "fb_accessor.h"
#include "regions.h"

// Shifts the waterfall region down by 1 row and writes a new top row from
// magnitudes[] colored through palette[]. Magnitudes are 0..255 indices
// into the palette LUT.
//
// Hardware note: the FPGA does not literally copy. It uses a base-row
// pointer modulo region height; scan-out applies the same modulo.
// Visible behavior is identical, which is what the golden tests verify.
void fb_compose_waterfall_step(fb_t *fb,
                               uint8_t layout,
                               const uint8_t magnitudes[800],
                               const uint16_t palette[256]);

// Writes one GOES row into the GOES region at row_y_in_region (0..region_h-1).
// Pixels are 0..255 grayscale; the compositor expands through the GOES palette
// and downsamples the source row into a square 480x480 image area.
void fb_compose_goes_row(fb_t *fb,
                         uint8_t layout,
                         uint16_t row_y_in_region,
                         const uint8_t pixels[800],
                         const uint16_t palette[256]);

// Draws the GOES side panel that fills the horizontal space left by the square
// image area.
void fb_compose_goes_panel(fb_t *fb,
                           uint8_t layout,
                           uint16_t row_y_in_region,
                           const aux_roms_t *roms);

// Fill a rectangular region with a solid color. Used on layout change.
void fb_compose_clear(fb_t *fb, region_t r, uint16_t color);

// ──────────────────────────────────────────────────────────────────────────────
// ADS-B map mode.
//
// One tracked aircraft: position in logical 800x480 map pixels, plus the
// compact metadata the map labels need. The renderer scales x/y into the
// post-header map viewport. The Zynq side computes x/y by projecting decoded
// ADS-B positions from UCR (the logical map center) onto the source map at
// ADSB_RADIUS_MI = ADSB_R_OUTER px.
// ──────────────────────────────────────────────────────────────────────────────

#define ADSB_MAX_PLANES 16
#define ADSB_IDENT_CHARS 8

// Logical source-map scale: UCR campus is the source center; the outer range
// ring is the nominal ADS-B reception radius. 75 mi maps to 224 px in the
// 800x448 basemap, then the renderer fits that map below the ADS-B header.
#define ADSB_RADIUS_MI 75
#define ADSB_R_OUTER   224

typedef struct {
    uint16_t x;
    uint16_t y;
    char     ident[ADSB_IDENT_CHARS + 1u];  // 8-char tail/callsign + local NUL
    uint16_t alt_ft;
    uint16_t speed_kt;
} adsb_plane_t;

// Redraws the whole ADS-B region: the host model loads the tracked Riverside
// RGB565 basemap when present, darkens it for display contrast, and falls back
// to a stylized UCR-centered placeholder otherwise. The header and ring labels
// use the 8x16 font, so the ROM bundle is passed in. Hardware still expects the
// same image in SDRAM (ADSB_BASEMAP) loaded from SPI config flash at boot — see
// the architecture doc §6.
void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes,
                           const aux_roms_t *roms);

#endif
