#ifndef TRIAD_FB_ACCESSOR_H
#define TRIAD_FB_ACCESSOR_H

#include <stdint.h>

#include "regions.h"

// Opaque framebuffer handle.
//
// On host: a wrapper around two uint16_t[480][800] buffers.
// On hardware: a wrapper around the SDRAM controller's request/grant
// interface plus a row-pointer for the waterfall ring (arch doc §7a).
//
// fb_compositor.c and pixel_shader.c go through this interface and
// nothing else in shared/ may touch FB memory.
typedef struct fb fb_t;

uint16_t fb_read(const fb_t *fb, uint16_t x, uint16_t y);

void fb_write(fb_t *fb, uint16_t x, uint16_t y, uint16_t rgb565);

void fb_write_row(fb_t *fb, uint16_t x, uint16_t y,
                  const uint16_t *src, uint16_t n);

void fb_swap(fb_t *fb);

#endif
