#include "fb_compositor.h"

#include "regions.h"
#include "screen_config.h"

// Host implementation: literal memmove for waterfall scroll. The FPGA uses
// a base-row pointer modulo the region height (arch doc §7a); visible
// behavior is identical, which is what the golden tests verify.

void fb_compose_waterfall_step(fb_t *fb,
                               uint8_t layout,
                               const uint8_t magnitudes[800],
                               const uint16_t palette[256]) {
    region_t r = region_for_kind(R_WATERFALL, layout);
    if (r.kind != R_WATERFALL || r.h < 2) return;

    // Scroll: row y ← row y-1, top-down, except top row.
    for (uint16_t y = (uint16_t)(r.y0 + r.h - 1); y > r.y0; y--) {
        for (uint16_t x = r.x0; x < r.x0 + r.w; x++) {
            fb_write(fb, x, y, fb_read(fb, x, (uint16_t)(y - 1)));
        }
    }

    // New top row from magnitudes mapped through palette.
    uint16_t scratch[SCREEN_W];
    uint16_t n = r.w < SCREEN_W ? r.w : SCREEN_W;
    for (uint16_t x = 0; x < n; x++) {
        scratch[x] = palette[magnitudes[x]];
    }
    fb_write_row(fb, r.x0, r.y0, scratch, n);
}

void fb_compose_goes_row(fb_t *fb,
                        uint8_t layout,
                        uint16_t row_y_in_region,
                        const uint8_t pixels[800],
                        const uint16_t palette[256]) {
    region_t r = region_for_kind(R_GOES, layout);
    if (r.kind != R_GOES) return;
    if (row_y_in_region >= r.h) return;

    uint16_t scratch[SCREEN_W];
    uint16_t n = r.w < SCREEN_W ? r.w : SCREEN_W;
    for (uint16_t x = 0; x < n; x++) {
        scratch[x] = palette[pixels[x]];
    }
    fb_write_row(fb, r.x0, (uint16_t)(r.y0 + row_y_in_region), scratch, n);
}

void fb_compose_clear(fb_t *fb, region_t r, uint16_t color) {
    if (!r.kind || r.w == 0 || r.h == 0) return;
    uint16_t scratch[SCREEN_W];
    uint16_t n = r.w < SCREEN_W ? r.w : SCREEN_W;
    for (uint16_t x = 0; x < n; x++) scratch[x] = color;
    for (uint16_t y = r.y0; y < r.y0 + r.h; y++) {
        fb_write_row(fb, r.x0, y, scratch, n);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// ADS-B map. Procedural placeholder basemap (dark ground, 64-px grid, one
// slanted "river" band standing in for the Santa Ana through Riverside) plus
// an amber dot per aircraft. All integer math — shifts, adds, compares — so it
// maps cleanly to a write-side FSM on the ECP5. TODO: replace the procedural
// basemap with a real Riverside map-image ROM; the plane overlay stays.
// ──────────────────────────────────────────────────────────────────────────────

#define ADSB_BG     RGB565(8, 20, 28)
#define ADSB_GRID   RGB565(20, 40, 52)
#define ADSB_RIVER  RGB565(28, 92, 130)
#define ADSB_PLANE  RGB565(255, 210, 40)
#define ADSB_CORE   RGB565(255, 255, 255)

static uint16_t adsb_basemap_pixel(uint16_t lx, uint16_t ly) {
    // Slanted river: center x walks right as we go down (rx = 120 + ly*3/4).
    uint16_t rx = (uint16_t)(120 + (ly * 3u) / 4u);
    uint16_t dx = (lx > rx) ? (uint16_t)(lx - rx) : (uint16_t)(rx - lx);
    if (dx < 14) return ADSB_RIVER;
    if ((lx & 63u) == 0 || (ly & 63u) == 0) return ADSB_GRID;
    return ADSB_BG;
}

void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes) {
    region_t r = region_for_kind(R_ADSB, layout);
    if (r.kind != R_ADSB || r.w == 0 || r.h == 0) return;

    uint16_t n = r.w < SCREEN_W ? r.w : SCREEN_W;

    // Basemap, row by row.
    uint16_t scratch[SCREEN_W];
    for (uint16_t ly = 0; ly < r.h; ly++) {
        for (uint16_t lx = 0; lx < n; lx++) {
            scratch[lx] = adsb_basemap_pixel(lx, ly);
        }
        fb_write_row(fb, r.x0, (uint16_t)(r.y0 + ly), scratch, n);
    }

    // Aircraft: a 5-px diamond (|dx|+|dy| <= 2) with a white core, clipped.
    for (uint8_t i = 0; i < n_planes && i < ADSB_MAX_PLANES; i++) {
        int32_t px = (int32_t)planes[i].x;
        int32_t py = (int32_t)planes[i].y;
        for (int32_t ddy = -2; ddy <= 2; ddy++) {
            for (int32_t ddx = -2; ddx <= 2; ddx++) {
                int32_t adx = ddx < 0 ? -ddx : ddx;
                int32_t ady = ddy < 0 ? -ddy : ddy;
                if (adx + ady > 2) continue;
                int32_t lx = px + ddx;
                int32_t ly = py + ddy;
                if (lx < 0 || lx >= (int32_t)r.w || ly < 0 || ly >= (int32_t)r.h) continue;
                uint16_t color = (adx + ady == 0) ? ADSB_CORE : ADSB_PLANE;
                fb_write(fb, (uint16_t)(r.x0 + lx), (uint16_t)(r.y0 + ly), color);
            }
        }
    }
}
