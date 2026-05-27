#ifndef TRIAD_FB_COMPOSITOR_H
#define TRIAD_FB_COMPOSITOR_H

#include <stdint.h>

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
// Pixels are 0..255 grayscale; the compositor expands through the GOES palette.
void fb_compose_goes_row(fb_t *fb,
                        uint8_t layout,
                        uint16_t row_y_in_region,
                        const uint8_t pixels[800],
                        const uint16_t palette[256]);

// Fill a rectangular region with a solid color. Used on layout change.
void fb_compose_clear(fb_t *fb, region_t r, uint16_t color);

// ──────────────────────────────────────────────────────────────────────────────
// ADS-B map mode.
//
// One tracked aircraft: position in region-local pixels (0..region_w-1,
// 0..region_h-1). Real ADS-B carries lat/lon/altitude/callsign; the renderer
// only needs a screen position, computed Pico-side from the decoded message.
// ──────────────────────────────────────────────────────────────────────────────

#define ADSB_MAX_PLANES 16

typedef struct {
    uint16_t x;
    uint16_t y;
} adsb_plane_t;

// Redraws the whole ADS-B region: a static basemap (currently a procedural
// placeholder for the Riverside-area map) plus a dot per aircraft. Slow-update
// — called only when the plane set changes, so unlike the waterfall this mode
// needs no back buffer. Real version blits a map-image ROM instead of the
// procedural basemap; the plane-dot overlay is unchanged.
void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes);

#endif
