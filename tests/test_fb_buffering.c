// Behavioral tests for the host framebuffer's double-buffer semantics.
//
// The golden compositor tests snapshot the BACK buffer immediately after a
// single compose, so they never exercise fb_swap or a multi-frame loop. These
// tests cover the two bugs behind the "framebuffer flickers / doesn't switch
// modes cleanly" report:
//
//   1. fb_swap must carry the just-composited image forward into the new back
//      buffer. Incremental compositing (waterfall/GOES scroll) read-modify-
//      writes its own prior rows; if the two planes keep independent
//      every-other-frame histories the display flickers between them.
//
//   2. fb_host_clear must wipe BOTH planes, so a region newly exposed by a
//      mode switch starts clean instead of showing the old mode's pixels.

#include <stdlib.h>
#include <string.h>

#include "fb_accessor.h"
#include "fb_compositor.h"
#include "palette.h"
#include "regions.h"
#include "screen_config.h"
#include "test_helpers.h"
#include "ui_state.h"

struct fb;
extern void test_fb_init(struct fb *fb, uint16_t fill);
extern void test_fb_clear(struct fb *fb, uint16_t color);
extern void test_fb_snapshot_back(const struct fb *fb, uint16_t *dst);
extern void test_fb_snapshot_front(const struct fb *fb, uint16_t *dst);

static struct fb *make_fb(uint16_t fill) {
    struct fb *fb = (struct fb *)malloc(2 * (size_t)SCREEN_W * SCREEN_H * sizeof(uint16_t) + 4);
    test_fb_init(fb, fill);
    return fb;
}

// After compositing into the back buffer and swapping, the new back buffer
// must equal the image we just composited - otherwise the next frame's
// incremental scroll builds on stale (two-frames-ago) content. The old
// plain-flip fb_swap left the new back untouched and failed this.
T_CASE(swap_carries_image_forward) {
    struct fb *fb = make_fb(0);

    // Distinct, position-dependent values so a stale plane can't coincidentally
    // match (a fill-0 plane would).
    for (uint16_t y = 0; y < SCREEN_H; y++)
        for (uint16_t x = 0; x < SCREEN_W; x++)
            fb_write((fb_t *)fb, x, y, (uint16_t)(((x * 7u) ^ (y * 13u)) | 1u));

    fb_swap((fb_t *)fb);

    int mismatches = 0;
    for (uint16_t y = 0; y < SCREEN_H; y++)
        for (uint16_t x = 0; x < SCREEN_W; x++)
            if (fb_read((fb_t *)fb, x, y) != (uint16_t)(((x * 7u) ^ (y * 13u)) | 1u))
                mismatches++;

    T_EXPECT_EQ(mismatches, 0);
    free(fb);
    return 0;
}

// The real anti-flicker invariant: a buffer that composites-and-swaps every
// frame must show the SAME image, frame for frame, as a single buffer that
// composites in place without swapping. With the buggy ping-pong the two
// diverge from the second frame on.
T_CASE(waterfall_no_divergence_across_swaps) {
    struct fb *swapping = make_fb(0);  // composes, snapshots, then swaps
    struct fb *single   = make_fb(0);  // composes in place, never swaps

    region_t r = region_for_kind(R_WATERFALL, (uint8_t)LAYOUT_SPECTRUM_ONLY);
    uint16_t *snap_s = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    uint16_t *snap_r = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));

    uint8_t mags[800];
    for (int step = 0; step < 6; step++) {
        for (int x = 0; x < 800; x++) mags[x] = (uint8_t)((x + step * 37) & 0xFF);

        fb_compose_waterfall_step((fb_t *)swapping, (uint8_t)LAYOUT_SPECTRUM_ONLY, mags, palette_waterfall);
        fb_compose_waterfall_step((fb_t *)single,   (uint8_t)LAYOUT_SPECTRUM_ONLY, mags, palette_waterfall);

        // The displayed frame is the back buffer just composited (scan-out
        // reads back before the swap, mirroring fpga_sim_tick).
        test_fb_snapshot_back(swapping, snap_s);
        test_fb_snapshot_back(single,   snap_r);

        int region_mismatches = 0;
        for (uint16_t y = r.y0; y < r.y0 + r.h; y++)
            for (uint16_t x = r.x0; x < r.x0 + r.w; x++)
                if (snap_s[(size_t)y * SCREEN_W + x] != snap_r[(size_t)y * SCREEN_W + x])
                    region_mismatches++;
        T_EXPECT_EQ(region_mismatches, 0);

        fb_swap((fb_t *)swapping);  // only the double-buffered one flips
    }

    free(snap_s); free(snap_r); free(swapping); free(single);
    return 0;
}

// A mode switch clears the framebuffer. The clear must hit BOTH planes, since
// either one can become the scanned-out front on the following frames.
T_CASE(clear_wipes_both_planes) {
    uint16_t fill = RGB565(255, 0, 0);
    struct fb *fb = make_fb(fill);

    // Dirty the back plane too, so it differs from the (filled) front plane.
    for (uint16_t x = 0; x < SCREEN_W; x++)
        fb_write((fb_t *)fb, x, 0, RGB565(0, 0, 255));

    uint16_t *front = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_front(fb, front);
    T_EXPECT(front[0] == fill);  // sanity: front was non-zero before the clear

    test_fb_clear(fb, 0);

    uint16_t *back = (uint16_t *)calloc((size_t)SCREEN_W * SCREEN_H, sizeof(uint16_t));
    test_fb_snapshot_front(fb, front);
    test_fb_snapshot_back(fb, back);

    int nonzero = 0;
    for (size_t i = 0; i < (size_t)SCREEN_W * SCREEN_H; i++) {
        if (front[i] != 0) nonzero++;
        if (back[i]  != 0) nonzero++;
    }
    T_EXPECT_EQ(nonzero, 0);

    free(front); free(back); free(fb);
    return 0;
}

int main(void) {
    T_RUN(swap_carries_image_forward);
    T_RUN(waterfall_no_divergence_across_swaps);
    T_RUN(clear_wipes_both_planes);
    T_FINISH();
}
