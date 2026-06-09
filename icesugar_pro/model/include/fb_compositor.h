#ifndef TRIAD_FB_COMPOSITOR_H
#define TRIAD_FB_COMPOSITOR_H

#include <stdint.h>

#include "aux_roms.h"
#include "fb_accessor.h"
#include "regions.h"

// Shifts the waterfall region down by 1 row and writes a new top row from
void fb_compose_waterfall_step(fb_t *fb,
                               uint8_t layout,
                               const uint8_t magnitudes[800],
                               const uint16_t palette[256]);

// Same visual append operation, but source the new row from the current
// 256-bin spectrum buffer. Older waterfall rows are left as-is; only the
// appended top row reflects the current DSP-side spectrum span.
void fb_compose_waterfall_spectrum_step(fb_t *fb,
                                        uint8_t layout,
                                        const uint16_t spectrum_bins[UI_SPECTRUM_BINS],
                                        uint16_t span_hz_log2,
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
// ADS-B map mode.
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
void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes,
                           uint8_t range_mi,
                           const aux_roms_t *roms);

#endif
