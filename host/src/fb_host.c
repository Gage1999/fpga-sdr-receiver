#include "fb_host.h"

#include <string.h>

#include "fb_accessor.h"

void fb_host_init(struct fb *fb, uint16_t fill) {
    fb->front = 0;
    for (int y = 0; y < SCREEN_H; y++)
        for (int x = 0; x < SCREEN_W; x++) {
            fb->a[y][x] = fill;
            fb->b[y][x] = fill;
        }
}

// Routes:
//   Reads (scan-out)    → FRONT buffer
//   Writes (compositor) → BACK buffer
// Then fb_swap flips front/back at "V-sync."
//
// The FPGA also uses double buffering (arch doc §6 has FB_FRONT/FB_BACK)
// — same visible semantics. The host doesn't model the SDRAM controller's
// request/grant or line-cache fill latency; the harness intentionally
// skips those (handoff §13). Golden tests verify visible behavior only.

static uint16_t (*front_plane(const struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? (uint16_t(*)[SCREEN_W])fb->a : (uint16_t(*)[SCREEN_W])fb->b;
}
static uint16_t (*back_plane(struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? fb->b : fb->a;
}
static const uint16_t (*back_plane_const(const struct fb *fb))[SCREEN_W] {
    return fb->front == 0 ? (const uint16_t(*)[SCREEN_W])fb->b
                          : (const uint16_t(*)[SCREEN_W])fb->a;
}

uint16_t fb_read(const fb_t *fb, uint16_t x, uint16_t y) {
    if (x >= SCREEN_W || y >= SCREEN_H) return 0;
    // Compositor reads its own writes during a frame (e.g. waterfall scroll
    // copies row y from row y-1). So reads go to BACK while compositing.
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
    fb->front ^= 1u;
}

void fb_host_snapshot_front(const struct fb *fb, uint16_t *dst) {
    memcpy(dst, front_plane(fb), SCREEN_W * SCREEN_H * sizeof(uint16_t));
}

void fb_host_snapshot_back(const struct fb *fb, uint16_t *dst) {
    memcpy(dst, back_plane_const(fb), SCREEN_W * SCREEN_H * sizeof(uint16_t));
}
