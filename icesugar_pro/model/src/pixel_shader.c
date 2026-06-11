#include "pixel_shader.h"

#include "regions.h"
#include "screen_config.h"
#include "ui_controls.h"

#define STATUS_FREQ_X        4u
#define STATUS_FREQ_Y        3u
#define STATUS_RDS_X         4u
#define STATUS_RDS_Y         32u
#define STATUS_RDS_CHARS     20u
#define SPECTRUM_BAND_X      4u
#define SPECTRUM_BAND_Y      2u
#define STATUS_VOL_X         204u
#define STATUS_VOL_Y         6u
#define STATUS_VOL_W         120u
#define STATUS_VOL_H         20u
#define STATUS_VOL_FILL_MAX  (STATUS_VOL_W - 4u)
#define STATUS_DEMOD_X       332u
#define STATUS_DEMOD_Y       3u
#define STATUS_DEMOD_CHARS   2u
// Button layout in the status bar - used by both shader and ui_logic for
// hit-testing. Kept here so the shader can render highlights without globals.
// Spectrum-page status bar is 800x64 starting at (0,0). Buttons use larger
// 48x48 hit targets and scale the existing 32x32 sprites.
static uint16_t brighten_rgb565(uint16_t px, uint8_t add) {
    uint8_t r = (uint8_t)RGB565_R(px);
    uint8_t g = (uint8_t)RGB565_G(px);
    uint8_t b = (uint8_t)RGB565_B(px);
    r = (uint8_t)((r + add > 255) ? 255 : r + add);
    g = (uint8_t)((g + add > 255) ? 255 : g + add);
    b = (uint8_t)((b + add > 255) ? 255 : b + add);
    return RGB565(r, g, b);
}

static uint16_t font16_row_for(const aux_roms_t *roms, char c, uint8_t gy) {
    uint8_t idx = (uint8_t)c;
    if (idx < FONT_16X32_FIRST || idx >= FONT_16X32_FIRST + FONT_16X32_COUNT) idx = '?';
    return roms->font_16x32[(uint32_t)(idx - FONT_16X32_FIRST) * FONT_16X32_H + gy];
}

static uint8_t label_ink(const char *label, uint8_t label_chars,
                         int32_t rel_x, int32_t rel_y,
                         const aux_roms_t *roms) {
    if (rel_x < 0 || rel_x >= (int32_t)label_chars * FONT_16X32_W ||
        rel_y < 0 || rel_y >= FONT_16X32_H) return 0u;

    uint8_t ch_idx = (uint8_t)(rel_x / FONT_16X32_W);
    uint8_t gx = (uint8_t)(rel_x % FONT_16X32_W);
    uint8_t gy = (uint8_t)rel_y;
    uint16_t row = font16_row_for(roms, label[ch_idx], gy);
    return (row & (uint16_t)(1u << (15 - gx))) != 0;
}

// Find the centered text origin for a label inside a UI_STATUS_BTN_W square.
// Runs in prepare(), not per-pixel - the inner loop is quadratic in glyph size.
static void label_origin(const char *label, uint8_t label_chars,
                         const aux_roms_t *roms,
                         int16_t *out_x, int16_t *out_y) {
    int32_t min_x = (int32_t)label_chars * FONT_16X32_W;
    int32_t min_y = FONT_16X32_H;
    int32_t max_x = -1;
    int32_t max_y = -1;

    for (int32_t y = 0; y < FONT_16X32_H; y++) {
        for (int32_t x = 0; x < (int32_t)label_chars * FONT_16X32_W; x++) {
            if (!label_ink(label, label_chars, x, y, roms)) continue;
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
        }
    }

    if (max_x < 0 || max_y < 0) {
        *out_x = 8;
        *out_y = 8;
        return;
    }

    int32_t ink_w = max_x - min_x + 1;
    int32_t ink_h = max_y - min_y + 1;
    *out_x = (int16_t)(((int32_t)UI_STATUS_BTN_W - ink_w) / 2 - min_x);
    *out_y = (int16_t)(((int32_t)UI_STATUS_BTN_W - ink_h) / 2 - min_y);
}

// Pick the sprite that represents a sprite-backed button given the current
// MUTE flag. The other sprite buttons (FREQ/VOL up/down) are fixed.
static uint8_t status_btn_sprite(uint8_t btn, uint8_t mute_sprite_id) {
    switch (btn) {
    case UI_BTN_FREQ_UP: return SPR_BTN_FREQ_UP;
    case UI_BTN_FREQ_DN: return SPR_BTN_FREQ_DN;
    case UI_BTN_VOL_UP:  return SPR_BTN_VOL_UP;
    case UI_BTN_VOL_DN:  return SPR_BTN_VOL_DN;
    case UI_BTN_MUTE:    return mute_sprite_id;
    default:             return SPR_ICON_BLANK;
    }
}

// Render one pixel of a centered-text button. text_x/text_y come from
// label_origin() and are passed in pre-computed by prepare().
static uint16_t draw_text_button(uint16_t local_x, uint16_t local_y,
                                 uint16_t bg, const char *label,
                                 uint8_t label_chars, uint8_t active,
                                 int16_t text_x, int16_t text_y,
                                 const aux_roms_t *roms) {
    const uint16_t fill = RGB565(24, 32, 42);
    const uint16_t edge = RGB565(156, 184, 204);
    const uint16_t fg = RGB565(245, 252, 255);
    uint16_t px = fill;

    if (local_x == 0 || local_y == 0 ||
        local_x == UI_STATUS_BTN_W - 1u || local_y == UI_STATUS_BTN_W - 1u) {
        px = edge;
    } else if (local_x < 3 || local_y < 3 ||
               local_x >= UI_STATUS_BTN_W - 3u || local_y >= UI_STATUS_BTN_W - 3u) {
        px = RGB565(48, 60, 74);
    }

    if (label_ink(label, label_chars,
                  (int32_t)local_x - (int32_t)text_x,
                  (int32_t)local_y - (int32_t)text_y,
                  roms)) px = fg;

    if (active && px != bg) px = brighten_rgb565(px, 48u);
    return px;
}

static uint16_t draw_status_button(uint16_t lx, uint16_t ly,
                                   uint8_t btn_id,
                                   uint16_t bg,
                                   const shader_state_t *st,
                                   const aux_roms_t *roms) {
    uint16_t x0 = ui_button_x0(btn_id);
    uint16_t y0 = ui_button_y0();
    if (lx < x0 || lx >= x0 + UI_STATUS_BTN_W ||
        ly < y0 || ly >= y0 + UI_STATUS_BTN_W) return bg;

    uint16_t local_x = (uint16_t)(lx - x0);
    uint16_t local_y = (uint16_t)(ly - y0);
    if (btn_id == UI_BTN_MODE) {
        return draw_text_button(local_x, local_y, bg,
                                st->mode_btn_label, 2u,
                                st->active_button == UI_BTN_MODE,
                                st->mode_btn_text_x, st->mode_btn_text_y, roms);
    }
    if (btn_id == UI_BTN_ZOOM_IN) {
        return draw_text_button(local_x, local_y, bg, "+", 1u,
                                st->active_button == UI_BTN_ZOOM_IN,
                                st->plus_text_x, st->plus_text_y, roms);
    }
    if (btn_id == UI_BTN_ZOOM_OUT) {
        return draw_text_button(local_x, local_y, bg, "-", 1u,
                                st->active_button == UI_BTN_ZOOM_OUT,
                                st->minus_text_x, st->minus_text_y, roms);
    }

    uint16_t spx = (uint16_t)((uint32_t)local_x * SPRITE_W / UI_STATUS_BTN_W);
    uint16_t spy = (uint16_t)((uint32_t)local_y * SPRITE_H / UI_STATUS_BTN_W);
    uint8_t sprite_id = status_btn_sprite(btn_id, st->mute_sprite_id);
    uint16_t px = roms->sprites[(uint32_t)sprite_id * SPRITE_PIXELS
                                + (uint32_t)spy * SPRITE_W + spx];
    if (px == 0) return bg;
    if (btn_id == st->active_button) return brighten_rgb565(px, 80u);
    return px;
}
// Text helpers - used by status bar.
// Returns pixel at (gx, gy) inside a 16x32 font glyph for char c, in `color` or `bg`.
static uint16_t glyph_pixel_16x32(char c, uint8_t gx, uint8_t gy,
                                  uint16_t color, uint16_t bg,
                                  const aux_roms_t *roms) {
    uint8_t idx = (uint8_t)c;
    if (idx < FONT_16X32_FIRST || idx >= FONT_16X32_FIRST + FONT_16X32_COUNT) idx = '?';
    uint16_t row = font16_row_for(roms, (char)idx, gy);
    uint16_t bit = (uint16_t)(1u << (15 - gx));
    return (row & bit) ? color : bg;
}

// Format the freq label into a 12-char buffer "NNN.NN MHz" (right-padded).
// Pure: no stdio. No malloc. Called once per frame from prepare().
static void format_freq_mhz(uint32_t freq_hz, char out[12]) {
    uint32_t mhz_int = freq_hz / 1000000u;
    uint32_t mhz_frac = (freq_hz % 1000000u) / 10000u;  // hundredths of MHz
    // Render as " NNN.NN MHz" (right-justify integer part to 3 chars).
    for (int i = 0; i < 12; i++) out[i] = ' ';

    char buf[8];
    int n = 0;
    if (mhz_int == 0) { buf[n++] = '0'; }
    else {
        char tmp[8];
        int t = 0;
        while (mhz_int > 0 && t < 8) { tmp[t++] = (char)('0' + (mhz_int % 10)); mhz_int /= 10; }
        while (t > 0) buf[n++] = tmp[--t];
    }
    int o = 3 - n;
    if (o < 0) o = 0;
    for (int i = 0; i < n && o + i < 3; i++) out[o + i] = buf[i];

    out[3] = '.';
    out[4] = (char)('0' + ((mhz_frac / 10) % 10));
    out[5] = (char)('0' + (mhz_frac % 10));
    out[6] = ' ';
    out[7] = 'M';
    out[8] = 'H';
    out[9] = 'z';
    out[10] = ' ';
    out[11] = ' ';
}

static uint16_t clamp_span_log2(uint16_t span_hz_log2) {
    if (span_hz_log2 < UI_SPAN_LOG2_MIN) return UI_SPAN_LOG2_MIN;
    if (span_hz_log2 > UI_SPAN_LOG2_MAX) return UI_SPAN_LOG2_MAX;
    return span_hz_log2;
}

static uint32_t span_hz_from_log2(uint16_t span_hz_log2) {
    span_hz_log2 = clamp_span_log2(span_hz_log2);
    return 1u << span_hz_log2;
}

static void format_mhz_3dp(uint32_t hz, char out[7]) {
    uint32_t khz = hz / 1000u;
    if (hz % 1000u >= 500u && khz < 0xFFFFFFFFu) khz++;

    uint32_t mhz_int = khz / 1000u;
    uint32_t frac = khz % 1000u;
    if (mhz_int > 999u) mhz_int = 999u;

    out[0] = (char)('0' + (mhz_int / 100u) % 10u);
    out[1] = (char)('0' + (mhz_int / 10u) % 10u);
    out[2] = (char)('0' + mhz_int % 10u);
    out[3] = '.';
    out[4] = (char)('0' + (frac / 100u) % 10u);
    out[5] = (char)('0' + (frac / 10u) % 10u);
    out[6] = (char)('0' + frac % 10u);
}

// Format as "LLL.lll-RRR.rrrMHz  " (20 chars, right-padded).
static void format_band_text(uint32_t center_hz, uint16_t span_hz_log2,
                             char out[SHADER_BAND_TEXT_CHARS]) {
    uint32_t span_hz = span_hz_from_log2(span_hz_log2);
    uint32_t half = span_hz >> 1;
    uint32_t lo = center_hz > half ? center_hz - half : 0u;
    uint32_t hi = (UINT32_MAX - center_hz < half) ? UINT32_MAX : center_hz + half;

    char left[7];
    char right[7];
    format_mhz_3dp(lo, left);
    format_mhz_3dp(hi, right);

    for (uint8_t i = 0; i < SHADER_BAND_TEXT_CHARS; i++) out[i] = ' ';
    for (uint8_t i = 0; i < 7; i++) out[i] = left[i];
    out[7] = '-';
    for (uint8_t i = 0; i < 7; i++) out[8 + i] = right[i];
    out[15] = 'M';
    out[16] = 'H';
    out[17] = 'z';
}

static void spectrum_window_for_span(uint16_t span_hz_log2,
                                     uint8_t *out_start,
                                     uint16_t *out_visible) {
    (void)span_hz_log2;
    *out_visible = UI_SPECTRUM_BINS;
    *out_start = 0u;
}

// Status bar layout: center frequency + visible band at the left, compact
// volume/mode in the middle, and touch buttons packed from the right.
static uint16_t shade_status(uint16_t lx, uint16_t ly, uint16_t w,
                             const shader_state_t *st, const aux_roms_t *roms) {
    const uint16_t bg = RGB565(20, 24, 32);
    const uint16_t fg = RGB565(220, 235, 255);
    const uint16_t accent = RGB565(80, 190, 255);
    const uint16_t dim = RGB565(165, 205, 225);

    (void)w;

    // Frequency text in cols 4..4+12*16 = 4..196.
    if (lx >= STATUS_FREQ_X && lx < STATUS_FREQ_X + 12 * 16 &&
        ly >= STATUS_FREQ_Y && ly < 32) {
        uint16_t col = (uint16_t)(lx - STATUS_FREQ_X);
        uint8_t ch_idx = (uint8_t)(col / 16);
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(st->freq_text[ch_idx], gx, (uint8_t)(ly - STATUS_FREQ_Y),
                                 fg, bg, roms);
    }

    // RDS/status text keeps the second status row free from spectrum zoom UI.
    if (st->demod == DEMOD_FM &&
        lx >= STATUS_RDS_X && lx < STATUS_RDS_X + STATUS_RDS_CHARS * 16 &&
        ly >= STATUS_RDS_Y && ly < 64) {
        uint16_t col = (uint16_t)(lx - STATUS_RDS_X);
        uint8_t ch_idx = (uint8_t)(col / 16);
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(st->rds_line[ch_idx], gx, (uint8_t)(ly - STATUS_RDS_Y),
                                 dim, bg, roms);
    }

    // Volume bar, centered on the top text row.
    if (lx >= STATUS_VOL_X && lx < STATUS_VOL_X + STATUS_VOL_W &&
        ly >= STATUS_VOL_Y && ly < STATUS_VOL_Y + STATUS_VOL_H) {
        uint16_t local_x = (uint16_t)(lx - STATUS_VOL_X);
        if (lx == STATUS_VOL_X || lx == STATUS_VOL_X + STATUS_VOL_W - 1u ||
            ly == STATUS_VOL_Y || ly == STATUS_VOL_Y + STATUS_VOL_H - 1u) return dim;
        return (local_x >= 2 && local_x - 2 < st->volume_fill_px)
               ? accent : RGB565(40, 48, 60);
    }

    // FM/AM demod label. Image modes do not have a status bar.
    if (lx >= STATUS_DEMOD_X && lx < STATUS_DEMOD_X + STATUS_DEMOD_CHARS * 16 &&
        ly >= STATUS_DEMOD_Y && ly < 32) {
        uint16_t col = (uint16_t)(lx - STATUS_DEMOD_X);
        uint8_t ch_idx = (uint8_t)(col / 16);
        if (ch_idx >= STATUS_DEMOD_CHARS) return bg;
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(st->demod_label[ch_idx], gx, (uint8_t)(ly - STATUS_DEMOD_Y),
                                 fg, bg, roms);
    }

    // Buttons.
    uint8_t btn_id;
    if (ui_button_hit(lx, ly, st->layout, &btn_id)) {
        return draw_status_button(lx, ly, btn_id, bg, st, roms);
    }

    return bg;
}

static uint16_t shade_image_mode_button(uint16_t x, uint16_t y,
                                        const shader_state_t *st,
                                        const aux_roms_t *roms,
                                        uint16_t under) {
    uint8_t btn_id;
    if (!ui_layout_is_image(st->layout)) return under;
    if (!ui_button_hit(x, y, st->layout, &btn_id)) return under;
    return draw_status_button(x, y, btn_id, RGB565(12, 18, 24), st, roms);
}
// Spectrum: draw bars from spectrum_bins[256] across the region width.
// Bin index = (lx * 256) / w. To stay FPGA-friendly, w is forced to a power
// of two at compile time (SCREEN_W = 800 isn't, so we use a fast approximate
// (lx * 256) >> 9 ~ lx / 2; flagged as TODO for a reciprocal LUT in SV).
static uint16_t shade_spectrum(uint16_t lx, uint16_t ly, uint16_t w, uint16_t h,
                               const shader_state_t *st, const aux_roms_t *roms) {
    const uint16_t bg = RGB565(10, 14, 22);
    const uint16_t bar = RGB565(120, 220, 140);
    const uint16_t grid = RGB565(30, 40, 60);
    const uint16_t band_fg = RGB565(165, 205, 225);

    uint16_t visible = st->spectrum_visible_bins;
    if (visible == 0 || visible > UI_SPECTRUM_BINS) visible = UI_SPECTRUM_BINS;

    // Match the SV bit-shift approximation exactly (pixel_shader.sv span_bin_off).
    uint16_t bin_off;
    switch (visible) {
        case 128: bin_off = (lx >> 3) + (lx >> 5) + (lx >> 8); break;
        case  64: bin_off = (lx >> 4) + (lx >> 6) + (uint16_t)(lx >> 9); break;
        case  32: bin_off = (lx >> 5) + (lx >> 7); break;
        case  16: bin_off = (lx >> 6) + (lx >> 8); break;
        case   8: bin_off = (lx >> 7) + (lx >= 700u ? 1u : 0u); break;
        default:  bin_off = (lx >> 2) + (lx >> 4) + (lx >> 7); break;
    }
    uint16_t bin_idx = (uint16_t)(st->spectrum_start_bin + bin_off);
    if (bin_idx >= UI_SPECTRUM_BINS) bin_idx = UI_SPECTRUM_BINS - 1;
    uint16_t mag = st->spectrum_bins[bin_idx];           // 0..65535
    uint32_t bar_h = ((uint32_t)mag * h) >> 16;          // 0..h
    uint16_t bar_top = (uint16_t)(h - bar_h);

    // Horizontal grid lines every 32 px.
    uint16_t base;
    if ((ly & 0x1F) == 0) base = grid;
    else if (ly >= bar_top) base = bar;
    else base = bg;

    // Current visible RF band. Drawn as a transparent overlay in the spectrum
    // area so the status row remains available for FM RDS text.
    if (st->layout == LAYOUT_SPECTRUM_ONLY &&
        lx >= SPECTRUM_BAND_X && lx < SPECTRUM_BAND_X + SHADER_BAND_TEXT_CHARS * 16 &&
        ly >= SPECTRUM_BAND_Y && ly < SPECTRUM_BAND_Y + 32u) {
        uint16_t col = (uint16_t)(lx - SPECTRUM_BAND_X);
        uint8_t ch_idx = (uint8_t)(col / 16);
        uint8_t gx = (uint8_t)(col % 16);
        uint16_t row = font16_row_for(roms, st->band_text[ch_idx],
                                      (uint8_t)(ly - SPECTRUM_BAND_Y));
        if ((row & (uint16_t)(1u << (15u - gx))) != 0u) return band_fg;
    }

    return base;
}
// Overlay: touch crosshair + (future) modals. Always called before region
// dispatch so it can supersede.
static uint16_t shade_overlay(uint16_t x, uint16_t y,
                              const shader_state_t *st, const aux_roms_t *roms,
                              uint16_t under) {
    (void)roms;
    if (!(st->flags & UI_FLAG_TOUCH_ACTIVE)) return under;

    int32_t dx = (int32_t)x - (int32_t)st->touch_x;
    int32_t dy = (int32_t)y - (int32_t)st->touch_y;
    int32_t adx = dx < 0 ? -dx : dx;
    int32_t ady = dy < 0 ? -dy : dy;

    // Crosshair: 1-px arms 12 long, 4-px gap from center.
    if (ady == 0 && adx > 4 && adx < 16) return RGB565(255, 255, 255);
    if (adx == 0 && ady > 4 && ady < 16) return RGB565(255, 255, 255);
    // Center dot
    if (adx <= 1 && ady <= 1) return RGB565(255, 80, 80);
    return under;
}
// Per-frame precompute. Lifts state-derived work out of the per-pixel path
// so the SV translation maps to a small combinational + ROM-lookup pipeline.
static void copy_demod_label(uint8_t demod, char out[4]) {
    const char *src;
    switch (demod) {
    case DEMOD_AM:   src = "AM  "; break;
    case DEMOD_GOES: src = "GOES"; break;
    case DEMOD_ADSB: src = "ADSB"; break;
    default:         src = "FM  "; break;
    }
    out[0] = src[0]; out[1] = src[1]; out[2] = src[2]; out[3] = src[3];
}

static void copy_mode_btn_label(uint8_t demod, char out[2]) {
    const char *src;
    switch (demod) {
    case DEMOD_AM:   src = "AM"; break;
    case DEMOD_GOES: src = "GO"; break;
    case DEMOD_ADSB: src = "AD"; break;
    default:         src = "FM"; break;
    }
    out[0] = src[0]; out[1] = src[1];
}

static void build_rds_line(const char *rds, char out[24]) {
    for (uint8_t i = 0; i < 24; i++) {
        char c = rds[i];
        out[i] = c ? c : ' ';
    }
}

void pixel_shader_prepare(const ui_state_t *ui, const aux_roms_t *roms,
                          shader_state_t *out) {
    out->layout         = ui->layout;
    out->demod          = ui->demod;
    out->flags          = ui->flags;
    out->active_button  = ui->active_button;
    out->touch_x        = ui->touch_x;
    out->touch_y        = ui->touch_y;
    out->spectrum_bins  = ui->spectrum_bins;

    format_freq_mhz(ui->freq_hz, out->freq_text);
    format_band_text(ui->freq_hz, ui->span_hz_log2, out->band_text);
    copy_demod_label(ui->demod, out->demod_label);
    build_rds_line(ui->rds_text, out->rds_line);
    copy_mode_btn_label(ui->demod, out->mode_btn_label);
    spectrum_window_for_span(ui->span_hz_log2,
                             &out->spectrum_start_bin,
                             &out->spectrum_visible_bins);

    label_origin(out->mode_btn_label, 2u, roms,
                 &out->mode_btn_text_x, &out->mode_btn_text_y);
    label_origin("+", 1u, roms, &out->plus_text_x, &out->plus_text_y);
    label_origin("-", 1u, roms, &out->minus_text_x, &out->minus_text_y);

    uint32_t fill = (uint32_t)ui->volume * STATUS_VOL_FILL_MAX / 100u;
    out->volume_fill_px = (uint16_t)(fill > STATUS_VOL_FILL_MAX ? STATUS_VOL_FILL_MAX : fill);

    out->mute_sprite_id = (ui->flags & UI_FLAG_MUTE) ? SPR_BTN_MUTE_ON : SPR_BTN_MUTE;
}
// Top-level dispatch.
uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const shader_state_t *st,
                      const aux_roms_t *roms) {
    region_t r = region_at(x, y, st->layout);
    uint16_t base;
    switch (r.kind) {
    case R_STATUS:
        base = shade_status((uint16_t)(x - r.x0), (uint16_t)(y - r.y0), r.w, st, roms);
        break;
    case R_SPECTRUM:
        base = shade_spectrum((uint16_t)(x - r.x0), (uint16_t)(y - r.y0), r.w, r.h, st, roms);
        break;
    case R_WATERFALL:
    case R_GOES:
    case R_ADSB:
        base = fb_under;
        break;
    default:
        base = RGB565(0, 0, 0);
        break;
    }
    base = shade_image_mode_button(x, y, st, roms, base);
    return shade_overlay(x, y, st, roms, base);
}
