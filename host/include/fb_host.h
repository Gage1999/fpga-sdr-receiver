#ifndef TRIAD_FB_HOST_H
#define TRIAD_FB_HOST_H

#include <stdint.h>

#include "fb_accessor.h"
#include "screen_config.h"

// Concrete host framebuffer - a pair of uint16_t[SCREEN_H][SCREEN_W] buffers.
// The opaque fb_t in shared/include/fb_accessor.h is defined here in the
// host build. Hardware build will define its own fb_t backed by SDRAM.

struct fb {
    uint16_t a[SCREEN_H][SCREEN_W];
    uint16_t b[SCREEN_H][SCREEN_W];
    uint8_t  front;  // 0 = a is front, 1 = b is front
    uint8_t  reserved[3];
};

void fb_host_init(struct fb *fb, uint16_t fill);

// Clear BOTH planes to `color`. Used on a layout (mode) change so regions
// newly exposed in the new mode don't show stale pixels from the old one.
void fb_host_clear(struct fb *fb, uint16_t color);

// Read out the current FRONT buffer as a contiguous row-major array of pixels.
// `dst` must hold SCREEN_W * SCREEN_H halfwords.
void fb_host_snapshot_front(const struct fb *fb, uint16_t *dst);

// Same, for the BACK buffer (the one the compositor writes into).
void fb_host_snapshot_back(const struct fb *fb, uint16_t *dst);

#endif
