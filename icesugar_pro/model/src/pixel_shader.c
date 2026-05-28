#include "pixel_shader.h"

#include "regions.h"
#include "screen_config.h"
#include "ui_controls.h"

// ──────────────────────────────────────────────────────────────────────────────
// Button layout in the status bar — used by both shader and ui_logic for
// hit-testing. Kept here so the shader can render highlights without globals.
//
// Spectrum-page status bar is 800x64 starting at (0,0). Buttons use larger
// 48x48 hit targets and scale the existing 32x32 sprites.
// ──────────────────────────────────────────────────────────────────────────────

// Pick the sprite that represents a button given the current UI state.
static uint8_t status_btn_sprite(uint8_t btn, const ui_state_t *ui) {
    switch (btn) {
    case UI_BTN_FREQ_UP: return SPR_BTN_FREQ_UP;
    case UI_BTN_FREQ_DN: return SPR_BTN_FREQ_DN;
    case UI_BTN_VOL_UP:  return SPR_BTN_VOL_UP;
    case UI_BTN_VOL_DN:  return SPR_BTN_VOL_DN;
    case UI_BTN_MODE:
        if (ui->demod == DEMOD_AM)   return SPR_BTN_MODE_AM;
        if (ui->demod == DEMOD_GOES) return SPR_BTN_MODE_GOES;
        // TODO: dedicated plane icon for ADS-B; reuse the SAT icon for now.
        if (ui->demod == DEMOD_ADSB) return SPR_ICON_SAT;
        return SPR_BTN_MODE_FM;
    case UI_BTN_MUTE:    return (ui->flags & UI_FLAG_MUTE)   ? SPR_BTN_MUTE_ON : SPR_BTN_MUTE;
    default:             return SPR_ICON_BLANK;
    }
}

static uint16_t draw_status_button(uint16_t lx, uint16_t ly,
                                   uint8_t btn_id,
                                   uint16_t bg,
                                   const ui_state_t *ui,
                                   const aux_roms_t *roms) {
    uint16_t x0 = ui_button_x0(btn_id);
    uint16_t y0 = ui_button_y0();
    if (lx < x0 || lx >= x0 + UI_STATUS_BTN_W ||
        ly < y0 || ly >= y0 + UI_STATUS_BTN_W) return bg;

    uint16_t local_x = (uint16_t)(lx - x0);
    uint16_t local_y = (uint16_t)(ly - y0);
    uint16_t spx = (uint16_t)((uint32_t)local_x * SPRITE_W / UI_STATUS_BTN_W);
    uint16_t spy = (uint16_t)((uint32_t)local_y * SPRITE_H / UI_STATUS_BTN_W);
    uint8_t sprite_id = status_btn_sprite(btn_id, ui);
    uint16_t px = roms->sprites[(uint32_t)sprite_id * SPRITE_PIXELS
                                + (uint32_t)spy * SPRITE_W + spx];
    if (px == 0) return bg;
    if (btn_id == ui->active_button) {
        uint8_t r = (uint8_t)RGB565_R(px);
        uint8_t g = (uint8_t)RGB565_G(px);
        uint8_t b = (uint8_t)RGB565_B(px);
        r = (uint8_t)((r + 80 > 255) ? 255 : r + 80);
        g = (uint8_t)((g + 80 > 255) ? 255 : g + 80);
        b = (uint8_t)((b + 80 > 255) ? 255 : b + 80);
        return RGB565(r, g, b);
    }
    return px;
}

// ──────────────────────────────────────────────────────────────────────────────
// Text helpers — used by status bar.
// ──────────────────────────────────────────────────────────────────────────────

// Returns pixel at (gx, gy) inside a 16x32 font glyph for char c, in `color` or `bg`.
static uint16_t glyph_pixel_16x32(char c, uint8_t gx, uint8_t gy,
                                  uint16_t color, uint16_t bg,
                                  const aux_roms_t *roms) {
    uint8_t idx = (uint8_t)c;
    if (idx < FONT_16X32_FIRST || idx >= FONT_16X32_FIRST + FONT_16X32_COUNT) idx = '?';
    uint16_t row = roms->font_16x32[(uint32_t)(idx - FONT_16X32_FIRST) * FONT_16X32_H + gy];
    uint16_t bit = (uint16_t)(1u << (15 - gx));
    return (row & bit) ? color : bg;
}

// Format the freq label into a 12-char buffer "NNN.NN MHz" (right-padded).
// Pure: no stdio. No malloc.
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

// Status bar layout: frequency + RDS text at the left, volume/mode in the
// middle, larger touch buttons packed from the right with MODE rightmost.
static uint16_t shade_status(uint16_t lx, uint16_t ly, uint16_t w,
                             const ui_state_t *ui, const aux_roms_t *roms) {
    const uint16_t bg = RGB565(20, 24, 32);
    const uint16_t fg = RGB565(220, 235, 255);
    const uint16_t accent = RGB565(80, 190, 255);
    const uint16_t dim = RGB565(165, 205, 225);

    (void)w;

    // Frequency text in cols 4..4+12*16 = 4..196.
    if (lx >= 4 && lx < 4 + 12 * 16 && ly < 32) {
        char text[12];
        format_freq_mhz(ui->freq_hz, text);
        uint16_t col = (uint16_t)(lx - 4);
        uint8_t ch_idx = (uint8_t)(col / 16);
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(text[ch_idx], gx, (uint8_t)ly, fg, bg, roms);
    }

    // Larger RDS/radio-text line, visible only in FM mode.
    if (ui->demod == DEMOD_FM && lx >= 4 && lx < 4 + 24 * 16 && ly >= 32 && ly < 64) {
        char text[24];
        text[0] = 'R'; text[1] = 'D'; text[2] = 'S'; text[3] = ' ';
        for (uint8_t i = 0; i < 20; i++) {
            char c = ui->rds_text[i];
            text[4 + i] = c ? c : ' ';
        }
        uint16_t col = (uint16_t)(lx - 4);
        uint8_t ch_idx = (uint8_t)(col / 16);
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(text[ch_idx], gx, (uint8_t)(ly - 32), dim, bg, roms);
    }

    // Volume bar at x=220..360, centered on the top text row.
    if (lx >= 220 && lx < 360 && ly >= 14 && ly < 34) {
        uint16_t local_x = (uint16_t)(lx - 220);
        if (lx == 220 || lx == 359 || ly == 14 || ly == 33) return dim;
        uint16_t fill = (uint16_t)((uint32_t)ui->volume * 136u / 100u);
        return (local_x >= 2 && local_x - 2 < fill) ? accent : RGB565(40, 48, 60);
    }

    // Demod label at x=372..436 — four 16x32 glyphs ("FM", "AM", "GOES", "ADSB").
    if (lx >= 372 && lx < 436 && ly < 32) {
        const char *lbl = (ui->demod == DEMOD_AM)   ? "AM  "
                        : (ui->demod == DEMOD_GOES) ? "GOES"
                        : (ui->demod == DEMOD_ADSB) ? "ADSB"
                        :                             "FM  ";
        uint16_t col = (uint16_t)(lx - 372);
        uint8_t ch_idx = (uint8_t)(col / 16);
        if (ch_idx >= 4) return bg;
        uint8_t gx = (uint8_t)(col % 16);
        return glyph_pixel_16x32(lbl[ch_idx], gx, (uint8_t)ly, fg, bg, roms);
    }

    // Buttons.
    uint8_t btn_id;
    if (ui_button_hit(lx, ly, ui->layout, &btn_id)) {
        return draw_status_button(lx, ly, btn_id, bg, ui, roms);
    }

    return bg;
}

static uint16_t shade_image_mode_button(uint16_t x, uint16_t y,
                                        const ui_state_t *ui,
                                        const aux_roms_t *roms,
                                        uint16_t under) {
    uint8_t btn_id;
    if (!ui_layout_is_image(ui->layout)) return under;
    if (!ui_button_hit(x, y, ui->layout, &btn_id)) return under;
    return draw_status_button(x, y, btn_id, RGB565(12, 18, 24), ui, roms);
}

// ──────────────────────────────────────────────────────────────────────────────
// Spectrum: draw bars from ui->spectrum_bins[256] across the region width.
// Bin index = (lx * 256) / w. To stay FPGA-friendly, w is forced to a power
// of two at compile time (SCREEN_W = 800 isn't, so we use a fast approximate
// (lx * 256) >> 9 ≈ lx / 2; flagged as TODO for a reciprocal LUT in SV).
// ──────────────────────────────────────────────────────────────────────────────

static uint16_t shade_spectrum(uint16_t lx, uint16_t ly, uint16_t w, uint16_t h,
                               const ui_state_t *ui) {
    const uint16_t bg = RGB565(10, 14, 22);
    const uint16_t bar = RGB565(120, 220, 140);
    const uint16_t grid = RGB565(30, 40, 60);

    // TODO_FPGA: replace this divide with a reciprocal LUT keyed on region width.
    uint16_t bin_idx = (uint16_t)((uint32_t)lx * UI_SPECTRUM_BINS / w);
    if (bin_idx >= UI_SPECTRUM_BINS) bin_idx = UI_SPECTRUM_BINS - 1;
    uint16_t mag = ui->spectrum_bins[bin_idx];           // 0..65535
    uint32_t bar_h = ((uint32_t)mag * h) >> 16;          // 0..h
    uint16_t bar_top = (uint16_t)(h - bar_h);

    // Horizontal grid lines every 32 px.
    if ((ly & 0x1F) == 0) return grid;

    if (ly >= bar_top) return bar;
    return bg;
}

// ──────────────────────────────────────────────────────────────────────────────
// Overlay: touch crosshair + (future) modals. Always called before region
// dispatch so it can supersede.
// ──────────────────────────────────────────────────────────────────────────────

static uint16_t shade_overlay(uint16_t x, uint16_t y,
                              const ui_state_t *ui, const aux_roms_t *roms,
                              uint16_t under) {
    (void)roms;
    if (!(ui->flags & UI_FLAG_TOUCH_ACTIVE)) return under;

    int32_t dx = (int32_t)x - (int32_t)ui->touch_x;
    int32_t dy = (int32_t)y - (int32_t)ui->touch_y;
    int32_t adx = dx < 0 ? -dx : dx;
    int32_t ady = dy < 0 ? -dy : dy;

    // Crosshair: 1-px arms 12 long, 4-px gap from center.
    if (ady == 0 && adx > 4 && adx < 16) return RGB565(255, 255, 255);
    if (adx == 0 && ady > 4 && ady < 16) return RGB565(255, 255, 255);
    // Center dot
    if (adx <= 1 && ady <= 1) return RGB565(255, 80, 80);
    return under;
}

// ──────────────────────────────────────────────────────────────────────────────
// Top-level dispatch.
// ──────────────────────────────────────────────────────────────────────────────

uint16_t pixel_shader(uint16_t x, uint16_t y,
                      uint16_t fb_under,
                      const ui_state_t *ui,
                      const aux_roms_t *roms) {
    region_t r = region_at(x, y, ui->layout);
    uint16_t base;
    switch (r.kind) {
    case R_STATUS:
        base = shade_status((uint16_t)(x - r.x0), (uint16_t)(y - r.y0), r.w, ui, roms);
        break;
    case R_SPECTRUM:
        base = shade_spectrum((uint16_t)(x - r.x0), (uint16_t)(y - r.y0), r.w, r.h, ui);
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
    base = shade_image_mode_button(x, y, ui, roms, base);
    return shade_overlay(x, y, ui, roms, base);
}
