#include "synth_data.h"

#include <math.h>
#include <string.h>

static uint32_t s_phase;
static uint32_t s_rng;
static uint32_t s_goes_counter;
static uint32_t s_goes_row;
static uint32_t s_adsb_counter;
static uint32_t s_adsb_tick;

#define ADSB_PLANE_COUNT 6u
#define ADSB_REGION_W    800
#define ADSB_REGION_H    448

static uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x ? x : 0xDEADBEEFu;
    return *s;
}

void synth_init(uint32_t seed) {
    s_phase = 0;
    s_rng = seed ? seed : 0xCAFEBABEu;
    s_goes_counter = 0;
    s_goes_row = 0;
    s_adsb_counter = 0;
    s_adsb_tick = 0;
}

void synth_spectrum_bins(uint16_t bins[256]) {
    s_phase++;
    // Two drifting peaks + low-floor noise — looks plausibly like a band scan.
    float center1 = 90.0f + 30.0f * sinf((float)s_phase * 0.013f);
    float center2 = 170.0f + 25.0f * sinf((float)s_phase * 0.021f + 1.7f);
    for (int i = 0; i < 256; i++) {
        float n = (float)(xorshift32(&s_rng) & 0x0FFFu) / 4096.0f;       // 0..1
        float d1 = ((float)i - center1) / 6.0f;
        float d2 = ((float)i - center2) / 9.0f;
        float p1 = expf(-d1 * d1) * 0.95f;
        float p2 = expf(-d2 * d2) * 0.7f;
        float v  = (p1 + p2) * 0.85f + n * 0.05f + 0.04f;
        if (v > 1.0f) v = 1.0f;
        bins[i] = (uint16_t)(v * 65535.0f);
    }
}

void synth_waterfall_row(uint8_t mags[800]) {
    // Reuse spectrum shape, stretched to 800 cols.
    uint16_t bins[256];
    synth_spectrum_bins(bins);  // advances s_phase
    for (int x = 0; x < 800; x++) {
        int bin_idx = (x * 256) / 800;
        uint16_t v = bins[bin_idx];
        mags[x] = (uint8_t)(v >> 8);
    }
}

bool synth_goes_row_ready(uint8_t pixels[800]) {
    s_goes_counter++;
    if (s_goes_counter < 4) return false;  // ~15 Hz at 60 fps host
    s_goes_counter = 0;

    // Build a vaguely satellite-image-shaped row: smooth band + edge tick.
    for (int x = 0; x < 800; x++) {
        float a = sinf((float)x * 0.012f + (float)s_goes_row * 0.05f) * 0.5f + 0.5f;
        float b = sinf((float)x * 0.04f) * 0.2f;
        float v = a + b * 0.5f;
        if (v < 0) v = 0;
        if (v > 1) v = 1;
        pixels[x] = (uint8_t)(v * 255.0f);
    }
    s_goes_row++;
    return true;
}

uint8_t synth_adsb_planes(adsb_plane_t *out, uint8_t max) {
    uint8_t n = (ADSB_PLANE_COUNT < max) ? (uint8_t)ADSB_PLANE_COUNT : max;
    for (uint8_t i = 0; i < n; i++) {
        // Deterministic start spread out across the map, each with a fixed
        // slow heading; positions wrap so planes never leave the region.
        int32_t bx = 80 + (int32_t)i * 110;
        int32_t by = 60 + (int32_t)((i * 73u) % 320u);
        int32_t vx = (i & 1u) ? 1 : -1;
        int32_t vy = (int32_t)(i % 3u) - 1;
        int32_t x = bx + vx * (int32_t)s_adsb_tick;
        int32_t y = by + vy * (int32_t)s_adsb_tick;
        x = ((x % ADSB_REGION_W) + ADSB_REGION_W) % ADSB_REGION_W;
        y = ((y % ADSB_REGION_H) + ADSB_REGION_H) % ADSB_REGION_H;
        out[i].x = (uint16_t)x;
        out[i].y = (uint16_t)y;
    }
    return n;
}

bool synth_adsb_dirty(void) {
    s_adsb_counter++;
    if (s_adsb_counter < 30) return false;  // ~2 Hz at 60 fps host
    s_adsb_counter = 0;
    s_adsb_tick++;
    return true;
}
