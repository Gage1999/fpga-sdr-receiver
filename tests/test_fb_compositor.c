#include <stdlib.h>
#include <string.h>

#include "fb_accessor.h"
#include "fb_compositor.h"
#include "golden_image.h"
#include "palette.h"
#include "regions.h"
#include "screen_config.h"
#include "test_helpers.h"
#include "ui_state.h"

int g_update_goldens = 0;
const char *g_golden_dir = "tests/golden";

struct fb;
extern void test_fb_init(struct fb *fb, uint16_t fill);
extern void test_fb_snapshot_back(const struct fb *fb, uint16_t *dst);

static struct fb *make_fb(uint16_t fill) {
    struct fb *fb = (struct fb *)malloc(2 * (size_t)SCREEN_W * SCREEN_H * sizeof(uint16_t) + 4);
    test_fb_init(fb, fill);
    return fb;
}

T_CASE(waterfall_one_step) {
    struct fb *fb = make_fb(0);
    uint8_t mags[800];
    for (int x = 0; x < 800; x++) mags[x] = (uint8_t)(x & 0xFF);

    fb_compose_waterfall_step((fb_t *)fb, (uint8_t)LAYOUT_SPLIT, mags, palette_waterfall);

    uint16_t *snap = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_back(fb, snap);
    T_EXPECT_EQ(check_golden("compositor_waterfall_1step", snap, SCREEN_W, SCREEN_H), 0);
    free(snap); free(fb);
    return 0;
}

T_CASE(waterfall_three_steps_distinct_rows) {
    struct fb *fb = make_fb(0);
    uint8_t mags[800];
    for (int step = 0; step < 3; step++) {
        for (int x = 0; x < 800; x++) mags[x] = (uint8_t)((x + step * 50) & 0xFF);
        fb_compose_waterfall_step((fb_t *)fb, (uint8_t)LAYOUT_SPLIT, mags, palette_waterfall);
    }
    uint16_t *snap = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_back(fb, snap);
    T_EXPECT_EQ(check_golden("compositor_waterfall_3steps", snap, SCREEN_W, SCREEN_H), 0);
    free(snap); free(fb);
    return 0;
}

T_CASE(region_clear_then_paint) {
    struct fb *fb = make_fb(RGB565(255, 0, 0));
    region_t r = region_for_kind(R_WATERFALL, (uint8_t)LAYOUT_SPLIT);
    fb_compose_clear((fb_t *)fb, r, RGB565(0, 255, 0));

    uint16_t *snap = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_back(fb, snap);
    T_EXPECT_EQ(check_golden("compositor_clear_waterfall_green", snap, SCREEN_W, SCREEN_H), 0);
    free(snap); free(fb);
    return 0;
}

T_CASE(goes_row_write) {
    struct fb *fb = make_fb(0);
    uint8_t pixels[800];
    for (int x = 0; x < 800; x++) pixels[x] = (uint8_t)(x / 4);
    region_t r = region_for_kind(R_GOES, (uint8_t)LAYOUT_SPLIT);
    fb_compose_goes_row((fb_t *)fb, (uint8_t)LAYOUT_SPLIT, (uint16_t)(r.h / 2), pixels, palette_goes);

    uint16_t *snap = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_back(fb, snap);
    T_EXPECT_EQ(check_golden("compositor_goes_row_mid", snap, SCREEN_W, SCREEN_H), 0);
    free(snap); free(fb);
    return 0;
}

T_CASE(adsb_frame_with_planes) {
    struct fb *fb = make_fb(0);
    adsb_plane_t planes[4] = {
        { 100, 60 }, { 400, 200 }, { 650, 350 }, { 770, 20 },
    };
    fb_compose_adsb_frame((fb_t *)fb, (uint8_t)LAYOUT_ADSB_FULL, planes, 4);

    uint16_t *snap = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_back(fb, snap);
    T_EXPECT_EQ(check_golden("compositor_adsb_frame", snap, SCREEN_W, SCREEN_H), 0);
    free(snap); free(fb);
    return 0;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--update-goldens") == 0) g_update_goldens = 1;
        else if (strncmp(argv[i], "--golden-dir=", 13) == 0) g_golden_dir = argv[i] + 13;
    }
    T_RUN(waterfall_one_step);
    T_RUN(waterfall_three_steps_distinct_rows);
    T_RUN(region_clear_then_paint);
    T_RUN(goes_row_write);
    T_RUN(adsb_frame_with_planes);
    T_FINISH();
}
