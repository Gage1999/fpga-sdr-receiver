#include <stdlib.h>
#include <string.h>

#include "aux_roms.h"
#include "fb_accessor.h"
#include "fb_compositor.h"
#include "golden_image.h"
#include "pixel_shader.h"
#include "regions.h"
#include "screen_config.h"
#include "test_helpers.h"
#include "ui_state.h"

int g_update_goldens = 0;
const char *g_golden_dir = "tests/golden";

struct fb;
extern void test_fb_init(struct fb *fb, uint16_t fill);

static struct fb *make_fb(uint16_t fill) {
    struct fb *fb = (struct fb *)malloc(2 * (size_t)SCREEN_W * SCREEN_H * sizeof(uint16_t) + 4);
    test_fb_init(fb, fill);
    return fb;
}

static void render_full(uint16_t *out, const ui_state_t *ui, struct fb *fb) {
    aux_roms_t roms; aux_roms_default(&roms);
    for (uint16_t y = 0; y < SCREEN_H; y++) {
        for (uint16_t x = 0; x < SCREEN_W; x++) {
            uint16_t under = fb_read((fb_t *)fb, x, y);
            out[(size_t)y * SCREEN_W + x] = pixel_shader(x, y, under, ui, &roms);
        }
    }
}

T_CASE(default_state_renders) {
    ui_state_t ui; ui_state_default(&ui);
    struct fb *fb = make_fb(RGB565(8, 12, 18));
    uint16_t *px = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    render_full(px, &ui, fb);
    T_EXPECT_EQ(check_golden("shader_default", px, SCREEN_W, SCREEN_H), 0);
    free(px); free(fb);
    return 0;
}

T_CASE(spectrum_with_bars) {
    ui_state_t ui; ui_state_default(&ui);
    for (int i = 0; i < UI_SPECTRUM_BINS; i++) {
        // Triangle wave for predictable goldens.
        uint16_t v = (uint16_t)(((i < 128 ? i : 255 - i) * 65535) / 128);
        ui.spectrum_bins[i] = v;
    }
    struct fb *fb = make_fb(0);
    uint16_t *px = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    render_full(px, &ui, fb);
    T_EXPECT_EQ(check_golden("shader_spectrum_triangle", px, SCREEN_W, SCREEN_H), 0);
    free(px); free(fb);
    return 0;
}

T_CASE(touch_overlay) {
    ui_state_t ui; ui_state_default(&ui);
    ui.flags |= UI_FLAG_TOUCH_ACTIVE;
    ui.touch_x = 400;
    ui.touch_y = 250;
    struct fb *fb = make_fb(RGB565(20, 20, 30));
    uint16_t *px = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    render_full(px, &ui, fb);
    T_EXPECT_EQ(check_golden("shader_touch_crosshair", px, SCREEN_W, SCREEN_H), 0);
    free(px); free(fb);
    return 0;
}

T_CASE(mute_button_lit) {
    ui_state_t ui; ui_state_default(&ui);
    ui.flags |= UI_FLAG_MUTE;
    ui.active_button = UI_BTN_MUTE;
    struct fb *fb = make_fb(0);
    uint16_t *px = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    render_full(px, &ui, fb);
    T_EXPECT_EQ(check_golden("shader_mute_active", px, SCREEN_W, SCREEN_H), 0);
    free(px); free(fb);
    return 0;
}

T_CASE(adsb_zoom_buttons_render) {
    ui_state_t ui; ui_state_default(&ui);
    ui.demod = DEMOD_ADSB;
    ui.layout = LAYOUT_ADSB_FULL;
    ui.adsb_range_mi = 75;

    struct fb *fb = make_fb(0);
    aux_roms_t roms;
    aux_roms_default(&roms);
    adsb_plane_t planes[4] = {
        { 100, 60,  "N321UA", 3200, 128 },
        { 400, 200, "N122SW", 5150, 142 },
        { 650, 350, "N45AA",  7000, 168 },
        { 770, 20,  "N738DL", 8900, 196 },
    };
    fb_compose_adsb_frame((fb_t *)fb, (uint8_t)LAYOUT_ADSB_FULL, planes, 4, 75, &roms);

    uint16_t *px = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    render_full(px, &ui, fb);
    T_EXPECT_EQ(check_golden("shader_adsb_zoom_buttons", px, SCREEN_W, SCREEN_H), 0);
    free(px); free(fb);
    return 0;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--update-goldens") == 0) g_update_goldens = 1;
        else if (strncmp(argv[i], "--golden-dir=", 13) == 0) g_golden_dir = argv[i] + 13;
    }
    T_RUN(default_state_renders);
    T_RUN(spectrum_with_bars);
    T_RUN(touch_overlay);
    T_RUN(mute_button_lit);
    T_RUN(adsb_zoom_buttons_render);
    T_FINISH();
}
