#include "regions.h"

#include "screen_config.h"

static region_t make_region(uint8_t kind, uint16_t x0, uint16_t y0, uint16_t w, uint16_t h) {
    region_t r = { kind, x0, y0, w, h };
    return r;
}

region_t region_for_kind(uint8_t kind, uint8_t layout) {
    switch (kind) {
    case R_STATUS:
        if (layout == LAYOUT_GOES_FULL || layout == LAYOUT_ADSB_FULL) return make_region(R_NONE, 0, 0, 0, 0);
        return make_region(R_STATUS, 0, 0, SCREEN_W, STATUS_H);

    case R_SPECTRUM:
        if (layout == LAYOUT_GOES_FULL || layout == LAYOUT_ADSB_FULL) return make_region(R_NONE, 0, 0, 0, 0);
        return make_region(R_SPECTRUM, 0, STATUS_H, SCREEN_W, SPECTRUM_H);

    case R_WATERFALL:
        if (layout == LAYOUT_GOES_FULL || layout == LAYOUT_ADSB_FULL) return make_region(R_NONE, 0, 0, 0, 0);
        // FM layout draws the spectrum on top and lets the waterfall fill the
        // rest of the screen. There's no FM+GOES split: FM and GOES can't run at
        // once (single RX LO).
        return make_region(R_WATERFALL, 0, STATUS_H + SPECTRUM_H,
                           SCREEN_W, SCREEN_H - STATUS_H - SPECTRUM_H);

    case R_GOES:
        if (layout == LAYOUT_GOES_FULL) {
            return make_region(R_GOES, 0, 0, SCREEN_W, GOES_FULL_H);
        }
        return make_region(R_NONE, 0, 0, 0, 0);

    case R_ADSB:
        if (layout == LAYOUT_ADSB_FULL) {
            return make_region(R_ADSB, 0, 0, SCREEN_W, ADSB_FULL_H);
        }
        return make_region(R_NONE, 0, 0, 0, 0);

    default:
        return make_region(R_NONE, 0, 0, 0, 0);
    }
}

region_t region_at(uint16_t x, uint16_t y, uint8_t layout) {
    if (x >= SCREEN_W || y >= SCREEN_H) return make_region(R_NONE, 0, 0, 0, 0);

    region_t r;

    r = region_for_kind(R_STATUS, layout);
    if (r.kind && y < r.y0 + r.h) return r;

    r = region_for_kind(R_SPECTRUM, layout);
    if (r.kind && y >= r.y0 && y < r.y0 + r.h) return r;

    r = region_for_kind(R_WATERFALL, layout);
    if (r.kind && y >= r.y0 && y < r.y0 + r.h) return r;

    r = region_for_kind(R_GOES, layout);
    if (r.kind && y >= r.y0 && y < r.y0 + r.h) return r;

    r = region_for_kind(R_ADSB, layout);
    if (r.kind && y >= r.y0 && y < r.y0 + r.h) return r;

    return make_region(R_NONE, 0, 0, 0, 0);
}
