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
// ADS-B map. Stylized UCR-centered placeholder: a center marker for the campus,
// concentric range rings at 25/50/75 mi (the outer being the nominal reception
// radius), a cardinal crosshair, and dimmer "beyond range" shading outside the
// outer ring. Aircraft are amber dots on top. All integer math — adds, multiplies,
// compares — so it maps to a write-side FSM on the ECP5. The real Riverside map
// image replaces only the basemap (see fb_compositor.h); rings/marker/planes stay.
// ──────────────────────────────────────────────────────────────────────────────

#define ADSB_CX        400   // region-local center (UCR), = w/2
#define ADSB_CY        224   //                            = h/2
#define ADSB_R_25      75    // 224 * 25/75
#define ADSB_R_50      149   // 224 * 50/75
// outer ring (75 mi) is ADSB_R_OUTER from the header

#define ADSB_IN_BG     RGB565(8, 20, 28)     // inside coverage
#define ADSB_OUT_BG    RGB565(3, 8, 12)      // beyond the outer ring
#define ADSB_RING_C    RGB565(40, 90, 80)    // range rings
#define ADSB_CARD_C    RGB565(24, 50, 46)    // cardinal crosshair
#define ADSB_CENTER_C  RGB565(90, 200, 255)  // UCR marker (cyan)
#define ADSB_LABEL_C   RGB565(120, 200, 180) // ring labels
#define ADSB_PLANE     RGB565(255, 210, 40)
#define ADSB_CORE      RGB565(255, 255, 255)

// True if d2 lands within ~2 px of the circle of radius R: (R-1)^2 <= d2 <= (R+1)^2.
static int adsb_on_ring(int32_t d2, int32_t R) {
    return d2 >= (R - 1) * (R - 1) && d2 <= (R + 1) * (R + 1);
}

static uint16_t adsb_basemap_pixel(uint16_t lx, uint16_t ly) {
    int32_t dx = (int32_t)lx - ADSB_CX;
    int32_t dy = (int32_t)ly - ADSB_CY;
    int32_t adx = dx < 0 ? -dx : dx;
    int32_t ady = dy < 0 ? -dy : dy;
    int32_t d2  = dx * dx + dy * dy;
    const int32_t r_out2 = ADSB_R_OUTER * ADSB_R_OUTER;

    if (adx + ady <= 3) return ADSB_CENTER_C;   // UCR marker (filled diamond)
    if (adsb_on_ring(d2, ADSB_R_25) ||
        adsb_on_ring(d2, ADSB_R_50) ||
        adsb_on_ring(d2, ADSB_R_OUTER)) return ADSB_RING_C;
    if (d2 <= r_out2 && (dx == 0 || dy == 0)) return ADSB_CARD_C;  // crosshair
    return (d2 <= r_out2) ? ADSB_IN_BG : ADSB_OUT_BG;
}

// Blit an ASCII string in the 8x16 font at region-local (lx, ly), clipped to r.
static void adsb_text(fb_t *fb, region_t r, int32_t lx, int32_t ly,
                      const char *s, uint16_t color, const uint8_t *font) {
    for (int ci = 0; s[ci]; ci++) {
        uint8_t idx = (uint8_t)s[ci];
        if (idx < FONT_8X16_FIRST || idx >= FONT_8X16_FIRST + FONT_8X16_COUNT) idx = '?';
        const uint8_t *glyph = &font[(uint32_t)(idx - FONT_8X16_FIRST) * FONT_8X16_H];
        for (uint8_t gy = 0; gy < FONT_8X16_H; gy++) {
            uint8_t row = glyph[gy];
            for (uint8_t gx = 0; gx < 8; gx++) {
                if (!(row & (uint8_t)(1u << (7 - gx)))) continue;
                int32_t X = lx + ci * 8 + gx;
                int32_t Y = ly + gy;
                if (X < 0 || X >= (int32_t)r.w || Y < 0 || Y >= (int32_t)r.h) continue;
                fb_write(fb, (uint16_t)(r.x0 + X), (uint16_t)(r.y0 + Y), color);
            }
        }
    }
}

void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes,
                           const aux_roms_t *roms) {
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

    // Labels: campus + range rings (distance in miles up the north axis).
    adsb_text(fb, r, ADSB_CX + 6,  ADSB_CY - 6,                "UCR",   ADSB_CENTER_C, roms->font_8x16);
    adsb_text(fb, r, ADSB_CX + 5,  ADSB_CY - ADSB_R_25 - 8,    "25",    ADSB_LABEL_C,  roms->font_8x16);
    adsb_text(fb, r, ADSB_CX + 5,  ADSB_CY - ADSB_R_50 - 8,    "50",    ADSB_LABEL_C,  roms->font_8x16);
    adsb_text(fb, r, ADSB_CX + 5,  ADSB_CY - ADSB_R_OUTER + 4, "75 MI", ADSB_LABEL_C,  roms->font_8x16);

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
