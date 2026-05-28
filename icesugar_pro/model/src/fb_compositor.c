#include "fb_compositor.h"

#include <stdio.h>

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
    uint16_t image_w = r.h < r.w ? r.h : r.w;
    if (image_w == 0 || row_y_in_region >= image_w) return;

    uint16_t scratch[SCREEN_W];
    uint16_t n = image_w < SCREEN_W ? image_w : SCREEN_W;
    for (uint16_t x = 0; x < n; x++) {
        uint16_t src_x = (uint16_t)((uint32_t)x * 800u / image_w);
        scratch[x] = palette[pixels[src_x]];
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
// ADS-B map. The host model loads the tracked Riverside RGB565 basemap when it
// is available; if not, it falls back to a stylized UCR/range-ring placeholder.
// Aircraft and range labels are drawn on top either way.
// ──────────────────────────────────────────────────────────────────────────────

#define ADSB_BASEMAP_W 800u
#define ADSB_BASEMAP_H 448u
#define ADSB_BASEMAP_PATH "icesugar_pro/model/assets/riverside_ucr.bin"

#define ADSB_IN_BG     RGB565(6, 18, 28)      // inside coverage
#define ADSB_OUT_BG    RGB565(2, 6, 12)       // beyond the outer ring
#define ADSB_RING_DIM  RGB565(0, 74, 88)      // range rings in fallback base
#define ADSB_RING_C    RGB565(0, 220, 255)    // range rings
#define ADSB_CENTER_C  RGB565(110, 235, 255)  // UCR marker (cyan)
#define ADSB_LABEL_C   RGB565(235, 250, 255)  // ring labels
#define ADSB_HEADER_H  64
#define ADSB_HEADER_BG RGB565(20, 24, 32)
#define ADSB_HEADER_FG RGB565(220, 235, 255)
#define ADSB_HEADER_2  RGB565(80, 190, 255)
#define ADSB_HEADER_DIM RGB565(165, 205, 225)
#define ADSB_SHADOW    RGB565(0, 0, 0)
#define ADSB_PLANE     RGB565(255, 220, 32)
#define ADSB_CORE      RGB565(255, 255, 255)

static uint16_t s_adsb_basemap[ADSB_BASEMAP_W * ADSB_BASEMAP_H];
static int s_adsb_basemap_state;  // 0 unknown, 1 loaded, -1 unavailable

static int adsb_load_basemap(void) {
    if (s_adsb_basemap_state != 0) return s_adsb_basemap_state == 1;

    FILE *f = fopen(ADSB_BASEMAP_PATH, "rb");
    if (!f) {
        s_adsb_basemap_state = -1;
        return 0;
    }

    for (uint32_t i = 0; i < ADSB_BASEMAP_W * ADSB_BASEMAP_H; i++) {
        int lo = fgetc(f);
        int hi = fgetc(f);
        if (lo < 0 || hi < 0) {
            fclose(f);
            s_adsb_basemap_state = -1;
            return 0;
        }
        s_adsb_basemap[i] = (uint16_t)((uint16_t)(uint8_t)lo | ((uint16_t)(uint8_t)hi << 8));
    }

    fclose(f);
    s_adsb_basemap_state = 1;
    return 1;
}

static int adsb_map_y0(uint16_t region_h) {
    return (region_h > ADSB_BASEMAP_H) ? (int)((region_h - ADSB_BASEMAP_H) / 2u) : 0;
}

typedef struct {
    int32_t x0;
    int32_t y0;
    int32_t w;
    int32_t h;
    int32_t src_x0;
    int32_t src_y0;
    int32_t src_w;
    int32_t src_h;
} adsb_view_t;

static uint8_t adsb_range_clamp(uint8_t range_mi) {
    if (range_mi <= 25u) return 25u;
    if (range_mi <= 50u) return 50u;
    return 75u;
}

static adsb_view_t adsb_view_for(region_t r, uint8_t range_mi) {
    int32_t avail_y = (r.h > ADSB_HEADER_H) ? ADSB_HEADER_H : 0;
    int32_t avail_h = (int32_t)r.h - avail_y;
    if (avail_h > 4) avail_h -= 4;  // keep the outer ring off the screen edge
    if (avail_h < 1) avail_h = 1;

    int32_t w = (int32_t)((uint32_t)ADSB_BASEMAP_W * (uint32_t)avail_h / ADSB_BASEMAP_H);
    int32_t h = avail_h;
    if (w > (int32_t)r.w) {
        w = r.w;
        h = (int32_t)((uint32_t)ADSB_BASEMAP_H * (uint32_t)w / ADSB_BASEMAP_W);
    }
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    adsb_view_t v;
    v.x0 = ((int32_t)r.w - w) / 2;
    v.y0 = avail_y + (((int32_t)r.h - avail_y) - h) / 2;
    v.w = w;
    v.h = h;
    range_mi = adsb_range_clamp(range_mi);
    v.src_w = (int32_t)((uint32_t)ADSB_BASEMAP_W * (uint32_t)range_mi / ADSB_RADIUS_MI);
    v.src_h = (int32_t)((uint32_t)ADSB_BASEMAP_H * (uint32_t)range_mi / ADSB_RADIUS_MI);
    if (v.src_w < 1) v.src_w = 1;
    if (v.src_h < 1) v.src_h = 1;
    v.src_x0 = ((int32_t)ADSB_BASEMAP_W - v.src_w) / 2;
    v.src_y0 = ((int32_t)ADSB_BASEMAP_H - v.src_h) / 2;
    return v;
}

static int32_t adsb_view_cx(adsb_view_t v) { return v.x0 + v.w / 2; }
static int32_t adsb_view_cy(adsb_view_t v) { return v.y0 + v.h / 2; }

static int32_t adsb_view_radius(adsb_view_t v, int32_t mi) {
    return (int32_t)((uint32_t)ADSB_R_OUTER * (uint32_t)mi * (uint32_t)v.h /
                    ((uint32_t)ADSB_RADIUS_MI * (uint32_t)v.src_h));
}

static int32_t adsb_project_x(adsb_view_t v, uint16_t logical_x) {
    int32_t x = logical_x;
    return v.x0 + (int32_t)(((int64_t)(x - v.src_x0) * v.w) / v.src_w);
}

static int32_t adsb_project_y(adsb_view_t v, uint16_t region_h, uint16_t logical_y) {
    int32_t src_y = (int32_t)logical_y - adsb_map_y0(region_h);
    return v.y0 + (int32_t)(((int64_t)(src_y - v.src_y0) * v.h) / v.src_h);
}

static int adsb_on_ring_width(int32_t d2, int32_t R, int32_t width) {
    int32_t inner = R - width;
    int32_t outer = R + width;
    if (inner < 0) inner = 0;
    return d2 >= inner * inner && d2 <= outer * outer;
}

static uint16_t adsb_night_pixel(uint16_t p) {
    uint16_t r = RGB565_R(p);
    uint16_t g = RGB565_G(p);
    uint16_t b = RGB565_B(p);
    uint16_t gray = (uint16_t)((30u * r + 59u * g + 11u * b) / 100u);
    uint16_t nr = (uint16_t)((gray * 20u) / 100u);
    uint16_t ng = (uint16_t)((gray * 28u) / 100u);
    uint16_t nb = (uint16_t)(12u + (gray * 42u) / 100u);
    if (nb > 104u) nb = 104u;
    return RGB565(nr, ng, nb);
}

static uint16_t adsb_basemap_pixel(region_t r, uint16_t lx, uint16_t ly, uint8_t range_mi) {
    adsb_view_t v = adsb_view_for(r, range_mi);
    if ((int32_t)lx < v.x0 || (int32_t)lx >= v.x0 + v.w ||
        (int32_t)ly < v.y0 || (int32_t)ly >= v.y0 + v.h) {
        return RGB565(2, 4, 8);
    }

    int32_t cx = adsb_view_cx(v);
    int32_t cy = adsb_view_cy(v);
    int32_t r25 = adsb_view_radius(v, 25);
    int32_t r50 = adsb_view_radius(v, 50);
    int32_t r75 = adsb_view_radius(v, ADSB_RADIUS_MI);
    int32_t dx = (int32_t)lx - cx;
    int32_t dy = (int32_t)ly - cy;
    int32_t adx = dx < 0 ? -dx : dx;
    int32_t ady = dy < 0 ? -dy : dy;
    int32_t d2  = dx * dx + dy * dy;
    const int32_t r_out2 = r75 * r75;

    if (adx + ady <= 3) return ADSB_CENTER_C;   // UCR marker (filled diamond)
    if (adsb_on_ring_width(d2, r25, 1) ||
        adsb_on_ring_width(d2, r50, 1) ||
        adsb_on_ring_width(d2, r75, 1)) return ADSB_RING_DIM;
    return (d2 <= r_out2) ? ADSB_IN_BG : ADSB_OUT_BG;
}

static uint16_t adsb_real_basemap_pixel(region_t r, uint16_t lx, uint16_t ly, uint8_t range_mi) {
    adsb_view_t v = adsb_view_for(r, range_mi);
    if ((int32_t)lx < v.x0 || (int32_t)lx >= v.x0 + v.w ||
        (int32_t)ly < v.y0 || (int32_t)ly >= v.y0 + v.h) {
        return RGB565(2, 4, 8);
    }
    uint16_t src_x = (uint16_t)(v.src_x0 + ((int32_t)lx - v.x0) * v.src_w / v.w);
    uint16_t src_y = (uint16_t)(v.src_y0 + ((int32_t)ly - v.y0) * v.src_h / v.h);
    if (src_x >= ADSB_BASEMAP_W) src_x = ADSB_BASEMAP_W - 1u;
    if (src_y >= ADSB_BASEMAP_H) src_y = ADSB_BASEMAP_H - 1u;
    return adsb_night_pixel(s_adsb_basemap[(uint32_t)src_y * ADSB_BASEMAP_W + src_x]);
}

static uint16_t adsb_overlay_pixel(region_t r, uint16_t lx, uint16_t ly, uint16_t base, uint8_t range_mi) {
    adsb_view_t v = adsb_view_for(r, range_mi);
    int32_t cx = adsb_view_cx(v);
    int32_t cy = adsb_view_cy(v);
    int32_t r25 = adsb_view_radius(v, 25);
    int32_t r50 = adsb_view_radius(v, 50);
    int32_t r75 = adsb_view_radius(v, ADSB_RADIUS_MI);
    int32_t dx = (int32_t)lx - cx;
    int32_t dy = (int32_t)ly - cy;
    int32_t adx = dx < 0 ? -dx : dx;
    int32_t ady = dy < 0 ? -dy : dy;
    int32_t d2  = dx * dx + dy * dy;

    if (adsb_on_ring_width(d2, r25, 2) ||
        adsb_on_ring_width(d2, r50, 2) ||
        adsb_on_ring_width(d2, r75, 2)) return ADSB_RING_C;
    if (adx + ady <= 5) return (adx + ady <= 2) ? ADSB_CORE : ADSB_CENTER_C;
    return base;
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

static void adsb_text_shadow(fb_t *fb, region_t r, int32_t lx, int32_t ly,
                             const char *s, uint16_t color, const uint8_t *font) {
    adsb_text(fb, r, (int32_t)(lx + 1), (int32_t)(ly + 1), s, ADSB_SHADOW, font);
    adsb_text(fb, r, lx, ly, s, color, font);
}

static void text16(fb_t *fb, region_t r, int32_t lx, int32_t ly,
                   const char *s, uint16_t color, const uint16_t *font) {
    for (int ci = 0; s[ci]; ci++) {
        uint8_t idx = (uint8_t)s[ci];
        if (idx < FONT_16X32_FIRST || idx >= FONT_16X32_FIRST + FONT_16X32_COUNT) idx = '?';
        const uint16_t *glyph = &font[(uint32_t)(idx - FONT_16X32_FIRST) * FONT_16X32_H];
        for (uint8_t gy = 0; gy < FONT_16X32_H; gy++) {
            uint16_t row = glyph[gy];
            for (uint8_t gx = 0; gx < 16; gx++) {
                if (!(row & (uint16_t)(1u << (15 - gx)))) continue;
                int32_t X = lx + ci * 16 + gx;
                int32_t Y = ly + gy;
                if (X < 0 || X >= (int32_t)r.w || Y < 0 || Y >= (int32_t)r.h) continue;
                fb_write(fb, (uint16_t)(r.x0 + X), (uint16_t)(r.y0 + Y), color);
            }
        }
    }
}

static void text16_shadow(fb_t *fb, region_t r, int32_t lx, int32_t ly,
                          const char *s, uint16_t color, const uint16_t *font) {
    text16(fb, r, (int32_t)(lx + 1), (int32_t)(ly + 1), s, ADSB_SHADOW, font);
    text16(fb, r, lx, ly, s, color, font);
}

static void adsb_fill_rect(fb_t *fb, region_t r, int32_t lx, int32_t ly,
                           int32_t w, int32_t h, uint16_t color) {
    for (int32_t yy = 0; yy < h; yy++) {
        int32_t y = ly + yy;
        if (y < 0 || y >= (int32_t)r.h) continue;
        for (int32_t xx = 0; xx < w; xx++) {
            int32_t x = lx + xx;
            if (x < 0 || x >= (int32_t)r.w) continue;
            fb_write(fb, (uint16_t)(r.x0 + x), (uint16_t)(r.y0 + y), color);
        }
    }
}

void fb_compose_goes_panel(fb_t *fb,
                           uint8_t layout,
                           uint16_t row_y_in_region,
                           const aux_roms_t *roms) {
    region_t r = region_for_kind(R_GOES, layout);
    if (r.kind != R_GOES || r.w <= r.h) return;

    int32_t image_w = r.h;
    int32_t panel_w = (int32_t)r.w - image_w;
    int32_t panel_x = image_w;
    uint16_t bg = RGB565(4, 8, 14);
    uint16_t line = RGB565(54, 86, 110);
    uint16_t fg = RGB565(228, 240, 250);
    uint16_t accent = RGB565(112, 220, 255);
    uint16_t warn = RGB565(255, 220, 110);

    adsb_fill_rect(fb, r, panel_x, 0, panel_w, r.h, bg);
    adsb_fill_rect(fb, r, panel_x, 0, 2, r.h, line);

    char row_line[24];
    char pct_line[24];
    uint16_t row = (row_y_in_region < r.h) ? row_y_in_region : (uint16_t)(r.h - 1u);
    uint16_t pct = (uint16_t)((uint32_t)(row + 1u) * 100u / r.h);
    snprintf(row_line, sizeof(row_line), "ROW %03u", (unsigned)(row + 1u));
    snprintf(pct_line, sizeof(pct_line), "FRAME %3u%%", (unsigned)pct);

    text16_shadow(fb, r, panel_x + 18, 24, "GOES", fg, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 84, row_line, accent, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 128, pct_line, accent, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 224, "HRIT SIM", fg, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 264, "1694.1 MHZ", fg, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 304, "TOP DOWN", fg, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 370, "WAIT FRAME", warn, roms->font_16x32);
    text16_shadow(fb, r, panel_x + 18, 410, "SYNC REAL RX", warn, roms->font_16x32);
}

static void adsb_ident_copy(const adsb_plane_t *p, uint8_t idx,
                            char out[ADSB_IDENT_CHARS + 1u]) {
    static const char *fallback[] = {
        "N321UA", "N122SW", "N45AA", "N738DL", "N500Q", "N71CA",
    };
    if (p->ident[0]) {
        uint8_t i = 0;
        for (; i < ADSB_IDENT_CHARS && p->ident[i]; i++) out[i] = p->ident[i];
        out[i] = '\0';
        return;
    }

    const char *ident = fallback[idx % (sizeof(fallback) / sizeof(fallback[0]))];
    uint8_t i = 0;
    for (; i < ADSB_IDENT_CHARS && ident[i]; i++) out[i] = ident[i];
    out[i] = '\0';
}

static void fb_compose_adsb_header(fb_t *fb,
                                   region_t r,
                                   const adsb_plane_t *planes,
                                   uint8_t n_planes,
                                   uint8_t range_mi,
                                   const aux_roms_t *roms) {
    char count_line[16];
    char ident_line[ADSB_IDENT_CHARS + 1u];
    char speed_line[16];
    uint8_t visible_planes = n_planes > 99u ? 99u : n_planes;
    snprintf(count_line, sizeof(count_line), "%02u ACFT", (unsigned)visible_planes);
    if (n_planes > 0) {
        adsb_ident_copy(&planes[0], 0, ident_line);
        snprintf(speed_line, sizeof(speed_line), "%uKT", (unsigned)planes[0].speed_kt);
    } else {
        snprintf(ident_line, sizeof(ident_line), "NO ACFT");
        snprintf(speed_line, sizeof(speed_line), "---KT");
    }

    adsb_fill_rect(fb, r, 0, 0, r.w, ADSB_HEADER_H, ADSB_HEADER_BG);
    adsb_fill_rect(fb, r, 0, ADSB_HEADER_H - 1, r.w, 1, RGB565(32, 44, 60));

    text16_shadow(fb, r, 4, 3, "1090.00 MHZ", ADSB_HEADER_FG, roms->font_16x32);
    text16_shadow(fb, r, 372, 3, "ADSB", ADSB_HEADER_FG, roms->font_16x32);
    text16_shadow(fb, r, 512, 3, "ZOOM", ADSB_HEADER_FG, roms->font_16x32);

    text16_shadow(fb, r, 4, 32, count_line, ADSB_HEADER_2, roms->font_16x32);
    text16_shadow(fb, r, 136, 32, ident_line, ADSB_HEADER_FG, roms->font_16x32);
    text16_shadow(fb, r, 256, 32, speed_line, ADSB_HEADER_DIM, roms->font_16x32);
    range_mi = adsb_range_clamp(range_mi);
    text16_shadow(fb, r, 512, 32, "25", range_mi == 25u ? ADSB_HEADER_2 : ADSB_HEADER_DIM, roms->font_16x32);
    text16_shadow(fb, r, 560, 32, "50", range_mi == 50u ? ADSB_HEADER_2 : ADSB_HEADER_DIM, roms->font_16x32);
    text16_shadow(fb, r, 608, 32, "75", range_mi == 75u ? ADSB_HEADER_2 : ADSB_HEADER_DIM, roms->font_16x32);
}

void fb_compose_adsb_frame(fb_t *fb,
                           uint8_t layout,
                           const adsb_plane_t *planes,
                           uint8_t n_planes,
                           uint8_t range_mi,
                           const aux_roms_t *roms) {
    region_t r = region_for_kind(R_ADSB, layout);
    if (r.kind != R_ADSB || r.w == 0 || r.h == 0) return;
    range_mi = adsb_range_clamp(range_mi);

    uint16_t n = r.w < SCREEN_W ? r.w : SCREEN_W;

    // Basemap, row by row.
    int have_real_map = adsb_load_basemap();
    uint16_t scratch[SCREEN_W];
    for (uint16_t ly = 0; ly < r.h; ly++) {
        for (uint16_t lx = 0; lx < n; lx++) {
            uint16_t base = have_real_map ? adsb_real_basemap_pixel(r, lx, ly, range_mi)
                                          : adsb_basemap_pixel(r, lx, ly, range_mi);
            scratch[lx] = adsb_overlay_pixel(r, lx, ly, base, range_mi);
        }
        fb_write_row(fb, r.x0, (uint16_t)(r.y0 + ly), scratch, n);
    }

    adsb_view_t view = adsb_view_for(r, range_mi);
    int32_t map_cx = adsb_view_cx(view);
    int32_t map_cy = adsb_view_cy(view);
    int32_t r25 = adsb_view_radius(view, 25);
    int32_t r50 = adsb_view_radius(view, 50);
    int32_t r75 = adsb_view_radius(view, ADSB_RADIUS_MI);

    // Labels: campus + range rings (distance in miles up the north axis).
    adsb_text_shadow(fb, r, map_cx + 8, map_cy - 8,       "UCR",   ADSB_CENTER_C, roms->font_8x16);
    adsb_text_shadow(fb, r, map_cx + 8, map_cy - r25 - 8, "25",    ADSB_LABEL_C,  roms->font_8x16);
    adsb_text_shadow(fb, r, map_cx + 8, map_cy - r50 - 8, "50",    ADSB_LABEL_C,  roms->font_8x16);
    adsb_text_shadow(fb, r, map_cx + 8, map_cy - r75 + 4, "75 MI", ADSB_LABEL_C,  roms->font_8x16);

    // Aircraft: larger high-contrast diamonds with a black halo, clipped.
    for (uint8_t i = 0; i < n_planes && i < ADSB_MAX_PLANES; i++) {
        int32_t px = adsb_project_x(view, planes[i].x);
        int32_t py = adsb_project_y(view, r.h, planes[i].y);
        for (int32_t pass = 0; pass < 2; pass++) {
            int32_t radius = pass == 0 ? 5 : 3;
            for (int32_t ddy = -radius; ddy <= radius; ddy++) {
                for (int32_t ddx = -radius; ddx <= radius; ddx++) {
                    int32_t adx = ddx < 0 ? -ddx : ddx;
                    int32_t ady = ddy < 0 ? -ddy : ddy;
                    if (adx + ady > radius) continue;
                    int32_t lx = px + ddx;
                    int32_t ly = py + ddy;
                    if (lx < 0 || lx >= (int32_t)r.w || ly < 0 || ly >= (int32_t)r.h) continue;
                    uint16_t color = ADSB_SHADOW;
                    if (pass == 1) color = (adx + ady <= 1) ? ADSB_CORE : ADSB_PLANE;
                    fb_write(fb, (uint16_t)(r.x0 + lx), (uint16_t)(r.y0 + ly), color);
                }
            }
        }

        char label[24];
        char ident[ADSB_IDENT_CHARS + 1u];
        adsb_ident_copy(&planes[i], i, ident);
        snprintf(label, sizeof(label), "%s %uFT", ident, (unsigned)planes[i].alt_ft);
        int32_t tx = px + 8;
        int32_t ty = py - 20;
        if (ty < 0) ty = py + 8;
        if (ty < ADSB_HEADER_H + 4) ty = py + 8;
        if (ty < ADSB_HEADER_H + 4) ty = ADSB_HEADER_H + 4;
        if (tx > (int32_t)r.w - 112) tx = px - 112;
        if (tx < 0) tx = 0;
        adsb_text_shadow(fb, r, tx, ty, label, ADSB_LABEL_C, roms->font_8x16);
    }

    fb_compose_adsb_header(fb, r, planes, n_planes, range_mi, roms);
}
