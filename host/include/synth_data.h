#ifndef TRIAD_SYNTH_DATA_H
#define TRIAD_SYNTH_DATA_H

#include <stdbool.h>
#include <stdint.h>

#include "fb_compositor.h"  // adsb_plane_t

// Synthesizes fake spectrum/waterfall/GOES data for the host harness, so we
// can develop UI without the Zynq side existing. Determinstic given the
// same seed, so screenshots are reproducible in CI.

void synth_init(uint32_t seed);

// One spectrum frame (256 bins, 0..65535) — call once per host_harness frame.
void synth_spectrum_bins(uint16_t bins[256]);

// One waterfall row (800 magnitude bytes, 0..255 indexing into the palette).
void synth_waterfall_row(uint8_t mags[800]);

// True every few host frames: GOES has a new line ready.
bool synth_goes_row_ready(uint8_t pixels[800]);

// Current GOES line position modulo the displayed region height. This lets the
// host model enter GOES mode mid-frame without pretending the next line is row 0.
uint16_t synth_goes_row_index(uint16_t region_h);

// Mock FM RDS text for the host harness until the Pluto-side RDS decoder feeds
// real station metadata.
void synth_rds_text(char *out, uint8_t out_cap);

// Mock ADS-B traffic: fills up to `max` aircraft positions in ADSB_FULL
// region-local pixels and returns the count. Deterministic given the seed.
uint8_t synth_adsb_planes(adsb_plane_t *out, uint8_t max);

// Advances the slow ADS-B clock; true a couple of times/sec when the plane
// positions have moved (so the host only recomposes the map when it changes).
bool synth_adsb_dirty(void);

#endif
