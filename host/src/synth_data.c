#include "synth_data.h"

#include <math.h>
#include <string.h>

#include "ui_state.h"

static uint32_t s_phase;
static uint32_t s_rng;
static uint32_t s_goes_counter;
static uint32_t s_goes_row;
static uint32_t s_adsb_counter;
static uint32_t s_adsb_tick;
static uint32_t s_rds_counter;

#define ADSB_PLANE_COUNT 6u
#define ADSB_REGION_W    800
#define ADSB_REGION_H    480

static uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x ? x : 0xDEADBEEFu;
    return *s;
}

static uint16_t clamp_span_log2(uint16_t span_hz_log2) {
    if (span_hz_log2 < UI_SPAN_LOG2_MIN) return UI_SPAN_LOG2_MIN;
    if (span_hz_log2 > UI_SPAN_LOG2_MAX) return UI_SPAN_LOG2_MAX;
    return span_hz_log2;
}

static float gaussian(float x) {
    return expf(-x * x);
}

void synth_init(uint32_t seed) {
    s_phase = 0;
    s_rng = seed ? seed : 0xCAFEBABEu;
    s_goes_counter = 0;
    s_goes_row = 0;
    s_adsb_counter = 0;
    s_adsb_tick = 0;
    s_rds_counter = 0;
}

void synth_spectrum_bins(uint16_t bins[256]) {
    synth_spectrum_bins_for_span(100000000u, 17u, bins);
}

void synth_spectrum_bins_for_span(uint32_t center_hz,
                                  uint16_t span_hz_log2,
                                  uint16_t bins[256]) {
    s_phase++;
    span_hz_log2 = clamp_span_log2(span_hz_log2);
    float span_hz = (float)(1u << span_hz_log2);

    // Mock real RF: peaks live at absolute Hz positions, while center_hz moves
    // the visible receiver window across them.
    const float rf_anchor_hz = 100000000.0f;
    float peak1_hz = rf_anchor_hz +
                     18000.0f * sinf((float)s_phase * 0.013f);
    float peak2_hz = rf_anchor_hz - 52000.0f +
                     9000.0f * sinf((float)s_phase * 0.021f + 1.7f);
    float peak3_hz = rf_anchor_hz + 96000.0f +
                     14000.0f * sinf((float)s_phase * 0.017f + 0.6f);
    float peak1_w = 1800.0f;
    float peak2_w = 4200.0f;
    float peak3_w = 6500.0f;
    float floor = 0.035f + 0.012f * (float)(UI_SPAN_LOG2_MAX - span_hz_log2);

    for (int i = 0; i < 256; i++) {
        float n = (float)(xorshift32(&s_rng) & 0x0FFFu) / 4096.0f;       // 0..1
        float bin_pos = ((float)i + 0.5f) / 256.0f - 0.5f;
        float bin_hz = ((float)center_hz) + bin_pos * span_hz;
        float p1 = gaussian((bin_hz - peak1_hz) / peak1_w) * 0.95f;
        float p2 = gaussian((bin_hz - peak2_hz) / peak2_w) * 0.70f;
        float p3 = gaussian((bin_hz - peak3_hz) / peak3_w) * 0.45f;
        float ripple = 0.025f * (sinf(bin_hz * 0.00021f + (float)s_phase * 0.031f) + 1.0f);
        float v  = (p1 + p2 + p3) * 0.85f + n * 0.045f + ripple + floor;
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

uint16_t synth_goes_row_index(uint16_t region_h) {
    if (region_h == 0) return 0;
    return (uint16_t)(s_goes_row % region_h);
}

void synth_rds_text(char *out, uint8_t out_cap) {
    static const char *msgs[] = {
        "KUCR 88.3  UCR RADIO",
        "FM STEREO",
        "CS122A SDR RECEIVER",
    };
    if (out_cap == 0) return;
    s_rds_counter++;
    const char *msg = msgs[(s_rds_counter / 240u) % (sizeof(msgs) / sizeof(msgs[0]))];
    uint8_t i = 0;
    for (; i + 1u < out_cap && msg[i]; i++) out[i] = msg[i];
    out[i] = '\0';
}

uint8_t synth_adsb_planes(adsb_plane_t *out, uint8_t max) {
    static const char *idents[] = {
        "N321UA", "N122SW", "N45AA", "N738DL", "N500Q", "N71CA",
    };
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
        memset(out[i].ident, 0, sizeof(out[i].ident));
        const char *ident = idents[i % (sizeof(idents) / sizeof(idents[0]))];
        for (uint8_t c = 0; c + 1u < sizeof(out[i].ident) && ident[c]; c++) {
            out[i].ident[c] = ident[c];
        }
        out[i].alt_ft = (uint16_t)(2400u + (uint16_t)i * 1850u);
        out[i].speed_kt = (uint16_t)(118u + (uint16_t)i * 17u);
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
