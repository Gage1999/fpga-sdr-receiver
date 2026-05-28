// Stand-in host framebuffer for tests. Same semantics as host/src/fb_host.c
// (compositor writes to BACK, reads see BACK, fb_swap flips), but lives
// inside the tests target so we don't drag SDL into CI.

#include <string.h>

#include "fb_accessor.h"
#include "screen_config.h"

struct fb {
    uint16_t a[SCREEN_H][SCREEN_W];
    uint16_t b[SCREEN_H][SCREEN_W];
    uint8_t  front;
    uint8_t  reserved[3];
};

void test_fb_init(struct fb *fb, uint16_t fill) {
    fb->front = 0;
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            fb->a[y][x] = fill;
            fb->b[y][x] = fill;
        }
}

static uint16_t (*back_plane(struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? fb->b : fb->a;
}
static const uint16_t (*back_plane_const(const struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? (const uint16_t(*)[SCREEN_W])fb->b
                          : (const uint16_t(*)[SCREEN_W])fb->a;
}
static const uint16_t (*front_plane_const(const struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? (const uint16_t(*)[SCREEN_W])fb->a
                          : (const uint16_t(*)[SCREEN_W])fb->b;
}

uint16_t fb_read(const fb_t *fb, uint16_t x, uint16_t y) {
    if (x >= SCREEN_W || y >= SCREEN_H) return 0;
    return back_plane_const(fb)[y][x];
}

void fb_write(fb_t *fb, uint16_t x, uint16_t y, uint16_t rgb565) {
    if (x >= SCREEN_W || y >= SCREEN_H) return;
    back_plane(fb)[y][x] = rgb565;
}

void fb_write_row(fb_t *fb, uint16_t x, uint16_t y,
                  const uint16_t *src, uint16_t n) {
    if (y >= SCREEN_H) return;
    if (x >= SCREEN_W) return;
    uint16_t avail = (uint16_t)(SCREEN_W - x);
    uint16_t copy = n < avail ? n : avail;
    memcpy(&back_plane(fb)[y][x], src, copy * sizeof(uint16_t));
}

void fb_swap(fb_t *fb) {
    // Mirror host/src/fb_host.c: copy the just-composited plane into the new
    // back so incremental compositing carries forward coherently (no
    // every-other-frame divergence). Tests snapshot BACK before swapping, so
    // this doesn't alter any golden result; it just keeps the semantics in sync.
    uint16_t (*old_back)[SCREEN_W] = back_plane(fb);
    fb->front ^= 1u;
    uint16_t (*new_back)[SCREEN_W] = back_plane(fb);
    memcpy(new_back, old_back, SCREEN_W * SCREEN_H * sizeof(uint16_t));
}

// Mirror host/src/fb_host.c::fb_host_clear — clear BOTH planes (used on a
// layout/mode change so newly exposed regions don't show stale pixels).
void test_fb_clear(struct fb *fb, uint16_t color) {
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            fb->a[y][x] = color;
            fb->b[y][x] = color;
        }
}

void test_fb_snapshot_back(const struct fb *fb, uint16_t *dst) {
    memcpy(dst, back_plane_const(fb), SCREEN_W * SCREEN_H * sizeof(uint16_t));
}

void test_fb_snapshot_front(const struct fb *fb, uint16_t *dst) {
    memcpy(dst, front_plane_const(fb), SCREEN_W * SCREEN_H * sizeof(uint16_t));
}
