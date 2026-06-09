#ifndef TRIAD_FB_ACCESSOR_H
#define TRIAD_FB_ACCESSOR_H

#include <stdint.h>

#include "regions.h"

// Opaque framebuffer handle.
typedef struct fb fb_t;

uint16_t fb_read(const fb_t *fb, uint16_t x, uint16_t y);

void fb_write(fb_t *fb, uint16_t x, uint16_t y, uint16_t rgb565);

void fb_write_row(fb_t *fb, uint16_t x, uint16_t y,
                  const uint16_t *src, uint16_t n);

void fb_swap(fb_t *fb);

#endif
